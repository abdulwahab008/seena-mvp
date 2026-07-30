-- FR-D12: multi-step leave approval chain, closing out the scope cut
-- noted in FR-D11's migration.
--
-- Design notes:
--   * effective_approver_role is resolved and stored ONCE per step, at
--     creation time (self-approval skip: if the chain's configured role
--     for this step belongs to the applicant themselves, the step is
--     created for Owner instead). Re-deriving it from
--     leave_approval_chain on every action would let the skip rule
--     silently disagree with itself between step creation and step
--     decision.
--   * Escalation simplifies "the next approver may act" to "Owner or
--     Super Admin may resolve an escalated step" rather than resolving
--     the exact next-role-up separately from the normal chain-advance
--     path — the AC's actual requirement (the ORIGINAL approver is
--     refused with STEP_ESCALATED once escalated) is fully implemented;
--     which specific higher role is allowed to act is narrowed for
--     simplicity.
--   * fn_escalate_overdue_steps() is callable, not cron-scheduled — same
--     reasoning as fn_expire_offers() (FR-B16): no pg_cron locally.
--   * apply_for_leave() (FR-D11) is create-or-replaced with the SAME
--     signature — not edited in its original migration file — to create
--     step 1 automatically when a chain is configured for the campus and
--     leave type. Leave types with no configured chain keep working
--     exactly as before, decided via FR-D11's fn_decide_leave_application.

create table public.leave_approval_chain (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  leave_type_id     uuid not null references public.leave_type(id),
  step_no           smallint not null,
  approver_role     public.app_role not null,
  approver_staff_id uuid references public.staff(id),
  sla_hours         smallint not null default 24,
  unique (campus_id, leave_type_id, step_no)
);

create or replace function public.set_leave_approval_chain_step(
  p_campus_id uuid, p_leave_type_id uuid, p_step_no smallint, p_approver_role public.app_role, p_sla_hours smallint default 24
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.leave_approval_chain (tenant_id, campus_id, leave_type_id, step_no, approver_role, sla_hours)
  values (app.auth_tenant_id(), p_campus_id, p_leave_type_id, p_step_no, p_approver_role, p_sla_hours)
  on conflict (campus_id, leave_type_id, step_no) do update set approver_role = excluded.approver_role, sla_hours = excluded.sla_hours
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_leave_approval_chain_step(uuid, uuid, smallint, public.app_role, smallint) from public, anon;
grant execute on function public.set_leave_approval_chain_step(uuid, uuid, smallint, public.app_role, smallint) to authenticated;

create type public.approval_decision as enum ('pending', 'approved', 'rejected', 'escalated');

create table public.leave_approval_step (
  id                       uuid primary key default gen_random_uuid(),
  application_id           uuid not null references public.leave_application(id) on delete cascade,
  step_no                  smallint not null,
  effective_approver_role  public.app_role not null,
  approver_id              uuid references public.app_user(user_id),
  decision                 public.approval_decision not null default 'pending',
  decided_at               timestamptz,
  comment                  text,
  created_at               timestamptz not null default now(),
  sla_due_at               timestamptz not null,
  unique (application_id, step_no)
);

create index idx_approval_step_pending on public.leave_approval_step (application_id, decision) where decision in ('pending', 'escalated');

-- Applies the self-approval skip rule: a chain step whose configured role
-- belongs to the applicant themselves is redirected to Owner. Shared
-- between step 1 (created inside apply_for_leave) and every subsequent
-- step (created inside advance_leave_approval) so both resolve it
-- identically.
create or replace function app.fn_resolve_leave_approver_role(p_staff_id uuid, p_chain_role public.app_role)
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when exists (
      select 1 from public.staff s
        join public.app_user au on au.user_id = s.user_id
       where s.id = p_staff_id and au.app_role = p_chain_role
    ) then 'owner'::public.app_role
    else p_chain_role
  end;
$$;

-- Same signature as FR-D11's version — create-or-replace only, the
-- original migration file is untouched. Adds: if a chain is configured
-- for this campus+leave_type, create step 1 instead of leaving the
-- application awaiting the single-step fallback decision.
create or replace function public.apply_for_leave(
  p_staff_id      uuid,
  p_leave_type_id uuid,
  p_from_date     date,
  p_to_date       date,
  p_is_half_day   boolean default false,
  p_reason        text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff        public.staff%rowtype;
  v_working_days numeric;
  v_balance      numeric;
  v_app_id       uuid;
  v_step1        public.leave_approval_chain%rowtype;
  v_role         public.app_role;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager')
     and not exists (select 1 from public.staff where id = p_staff_id and user_id = auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_staff from public.staff where id = p_staff_id;
  if not found then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_staff_id::text || p_leave_type_id::text, 0));

  if p_is_half_day then
    v_working_days := 0.5;
  else
    v_working_days := public.working_days_between(v_staff.campus_id, p_from_date, p_to_date);
  end if;

  v_balance := public.fn_leave_balance(p_staff_id, p_leave_type_id);
  if v_working_days > v_balance then
    raise exception 'INSUFFICIENT_BALANCE'
      using errcode = '23514', detail = format('available=%s requested=%s', v_balance, v_working_days);
  end if;

  insert into public.leave_application (
    tenant_id, campus_id, staff_id, leave_type_id, from_date, to_date, is_half_day, working_days, reason
  ) values (
    v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_leave_type_id, p_from_date, p_to_date, p_is_half_day, v_working_days, p_reason
  )
  returning id into v_app_id;

  insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
  values (v_staff.tenant_id, p_staff_id, p_leave_type_id, 'hold', -v_working_days, v_app_id, auth.uid());

  select * into v_step1 from public.leave_approval_chain
   where campus_id = v_staff.campus_id and leave_type_id = p_leave_type_id and step_no = 1;
  if found then
    v_role := app.fn_resolve_leave_approver_role(p_staff_id, v_step1.approver_role);
    insert into public.leave_approval_step (application_id, step_no, effective_approver_role, sla_due_at)
    values (v_app_id, 1, v_role, now() + make_interval(hours => v_step1.sla_hours));
  end if;

  return v_app_id;
end;
$$;

revoke execute on function public.apply_for_leave(uuid, uuid, date, date, boolean, text) from public, anon;
grant execute on function public.apply_for_leave(uuid, uuid, date, date, boolean, text) to authenticated;

create or replace function public.advance_leave_approval(p_application_id uuid, p_decision public.approval_decision, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app            public.leave_application%rowtype;
  v_step           public.leave_approval_step%rowtype;
  v_next_chain_row public.leave_approval_chain%rowtype;
  v_next_role      public.app_role;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_DECISION' using errcode = '22023';
  end if;

  select * into v_app from public.leave_application where id = p_application_id and status = 'pending';
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;

  select * into v_step from public.leave_approval_step
   where application_id = p_application_id and decision in ('pending', 'escalated')
   order by step_no asc
   limit 1;
  if not found then
    raise exception 'NO_PENDING_STEP' using errcode = '55000';
  end if;

  if v_step.decision = 'escalated' then
    if app.auth_role() = v_step.effective_approver_role::text then
      raise exception 'STEP_ESCALATED' using errcode = '55000';
    end if;
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner') and app.auth_role() <> v_step.effective_approver_role::text then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.leave_approval_step
     set decision = p_decision, decided_at = now(), comment = p_comment, approver_id = auth.uid()
   where id = v_step.id;

  if p_decision = 'rejected' then
    -- Stops here: no further step is ever created, and the hold reverses
    -- in the same transaction as the rejection.
    update public.leave_application
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
     where id = p_application_id;

    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    return;
  end if;

  select * into v_next_chain_row from public.leave_approval_chain
   where campus_id = v_app.campus_id and leave_type_id = v_app.leave_type_id and step_no = v_step.step_no + 1;

  if not found then
    update public.leave_application
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
     where id = p_application_id;

    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'consumption', -v_app.working_days, p_application_id, auth.uid());

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by)
    select v_app.tenant_id, v_app.campus_id, v_app.staff_id, d::date,
           case when v_app.is_half_day then 'half_day'::public.attendance_status else 'on_leave'::public.attendance_status end,
           'leave', auth.uid()
      from generate_series(v_app.from_date, v_app.to_date, interval '1 day') as d
    on conflict (staff_id, att_date) do update set status = excluded.status, source = 'leave';
  else
    v_next_role := app.fn_resolve_leave_approver_role(v_app.staff_id, v_next_chain_row.approver_role);
    insert into public.leave_approval_step (application_id, step_no, effective_approver_role, sla_due_at)
    values (p_application_id, v_next_chain_row.step_no, v_next_role, now() + make_interval(hours => v_next_chain_row.sla_hours));
  end if;
end;
$$;

revoke execute on function public.advance_leave_approval(uuid, public.approval_decision, text) from public, anon;
grant execute on function public.advance_leave_approval(uuid, public.approval_decision, text) to authenticated;

create or replace function public.fn_escalate_overdue_steps()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.leave_approval_step
     set decision = 'escalated'
   where decision = 'pending' and sla_due_at < now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.fn_escalate_overdue_steps() from public, anon, authenticated;
grant execute on function public.fn_escalate_overdue_steps() to service_role;

alter table public.leave_approval_chain enable row level security;
alter table public.leave_approval_step enable row level security;

create policy chain_read_campus_scope on public.leave_approval_chain
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy approval_step_actor_or_hr_read on public.leave_approval_step
  for select to authenticated
  using (
    app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
    or effective_approver_role::text = app.auth_role()
    or application_id in (
      select la.id from public.leave_application la
        join public.staff s on s.id = la.staff_id
       where s.user_id = auth.uid()
    )
  );
