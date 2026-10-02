-- FR-K04: per-student fee plan snapshot.
--
-- Accounting-specific care: this is a SNAPSHOT, never a live join. If
-- challan generation later read fee_structure_line directly at run time,
-- a back-dated structure edit would silently rewrite two years of past
-- billing. build_fee_plan() copies the published structure's applicable
-- lines onto fee_plan_line once, at enrolment time, each recording its
-- own source_structure_line_id for traceability — the plan is then the
-- only thing anything downstream (challans, K09) ever reads.
--
-- Money is bigint paisa throughout, same discipline as FR-K02.
--
-- The override gate (AC: lowering TUITION enters pending_approval and is
-- not live until a Principal approves) is the control that stops a
-- front-desk clerk quietly zeroing a fee — propose_fee_plan_override()
-- never touches amount_paisa itself, only decide_fee_plan_override()
-- (Principal/Owner/Super Admin, approving) does.
--
-- Removal is end-dating (effective_to), never delete: a challan already
-- issued for the current month must stay correct even after the line
-- stops applying — matches the AC's "removed 15 March, March challan
-- untouched, takes effect in April" example exactly.
--
-- Scope cuts:
--   * Group-specific lines (e.g. LAB only for Pre-Medical) are NOT
--     resolved here — enrolment has no group/stream column at all (group
--     lives only on admission_application.group_applied, and nothing
--     copies it onto enrolment). build_fee_plan() only ever picks up
--     class-wide lines (group_code is null). Resolving a student's actual
--     elective group at enrolment time is a real, separate schema gap,
--     not something to paper over here.
--   * The TRANSPORT-conditional line (AC: omitted with no route, added
--     from the next billing period once a route exists) is implemented
--     exactly as specified, keyed off student_transport.route_id — but
--     FR-C07 already shipped route_id/stop_id nullable with "nothing
--     binds them yet" (no route-assignment feature exists). The
--     condition is correct and will start mattering the day route
--     assignment ships; there's no way to demonstrate the "route added
--     later" half of the AC against real UI-driven data until then.

create type public.fee_plan_override_status as enum ('none', 'pending_approval', 'approved', 'rejected');

create table public.fee_plan (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  session_id    uuid not null references public.academic_session(id) on delete cascade,
  structure_id  uuid not null references public.fee_structure(id),
  effective_from date not null default current_date,
  created_at    timestamptz not null default now(),
  unique (enrolment_id)
);

create table public.fee_plan_line (
  id                       uuid primary key default gen_random_uuid(),
  plan_id                  uuid not null references public.fee_plan(id) on delete cascade,
  fee_head_id              uuid not null references public.fee_head(id),
  amount_paisa             bigint not null check (amount_paisa >= 0),
  frequency                public.fee_frequency not null,
  billing_month_mask       smallint not null,
  source_structure_line_id uuid references public.fee_structure_line(id),
  effective_from           date not null default current_date,
  effective_to             date,
  pending_amount_paisa     bigint,
  override_reason          text,
  override_status          public.fee_plan_override_status not null default 'none',
  approved_by              uuid references public.app_user(user_id),
  approved_at              timestamptz,
  created_at               timestamptz not null default now()
);

create index idx_fee_plan_line_plan on public.fee_plan_line (plan_id);

create trigger fee_plan_line_audit after insert or update or delete on public.fee_plan_line
  for each row execute function app.tg_audit_row();

create or replace function public.build_fee_plan(p_enrolment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment    public.enrolment%rowtype;
  v_structure_id uuid;
  v_plan_id      uuid;
  v_has_route    boolean;
begin
  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select id into v_structure_id from public.fee_structure
   where campus_id = v_enrolment.campus_id and session_id = v_enrolment.session_id and status = 'published'
   limit 1;
  if v_structure_id is null then
    -- No published structure yet for this campus/session — nothing to
    -- snapshot. Enrolment itself must never be blocked by billing not
    -- being configured yet; this is a deliberate silent no-op, not an error.
    return null;
  end if;

  select exists(
    select 1 from public.student_transport
     where student_id = v_enrolment.student_id and session_id = v_enrolment.session_id
       and opt_in and route_id is not null and to_date is null
  ) into v_has_route;

  insert into public.fee_plan (tenant_id, campus_id, enrolment_id, session_id, structure_id)
  values (v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, v_enrolment.session_id, v_structure_id)
  on conflict (enrolment_id) do nothing
  returning id into v_plan_id;

  if v_plan_id is null then
    select id into v_plan_id from public.fee_plan where enrolment_id = p_enrolment_id;
    return v_plan_id;
  end if;

  insert into public.fee_plan_line (plan_id, fee_head_id, amount_paisa, frequency, billing_month_mask, source_structure_line_id)
  select v_plan_id, l.fee_head_id, l.amount_paisa, l.frequency, l.billing_month_mask, l.id
    from public.fee_structure_line l
    join public.fee_head fh on fh.id = l.fee_head_id
   where l.structure_id = v_structure_id and l.class_id = v_enrolment.class_level_id and l.group_code is null
     and (fh.code <> 'TRANSPORT' or v_has_route);

  return v_plan_id;
end;
$$;

revoke execute on function public.build_fee_plan(uuid) from public, anon;
grant execute on function public.build_fee_plan(uuid) to authenticated;

create or replace function app.tg_enrolment_build_fee_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.build_fee_plan(new.id);
  return new;
end;
$$;

create trigger enrolment_ai_build_fee_plan after insert on public.enrolment
  for each row execute function app.tg_enrolment_build_fee_plan();

create or replace function public.propose_fee_plan_override(p_line_id uuid, p_new_amount_paisa bigint, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;

  select fp.tenant_id into v_tenant_id
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.fee_plan_line
     set pending_amount_paisa = p_new_amount_paisa, override_reason = p_reason, override_status = 'pending_approval'
   where id = p_line_id;
end;
$$;

revoke execute on function public.propose_fee_plan_override(uuid, bigint, text) from public, anon;
grant execute on function public.propose_fee_plan_override(uuid, bigint, text) to authenticated;

-- The one function allowed to move amount_paisa once a plan line already
-- has one — everywhere else, amount_paisa is set once, at snapshot time.
create or replace function public.decide_fee_plan_override(p_line_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line public.fee_plan_line%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select fpl.* into v_line
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id and fp.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_line.override_status <> 'pending_approval' then
    raise exception 'OVERRIDE_NOT_PENDING' using errcode = '55000';
  end if;

  if p_approve then
    update public.fee_plan_line
       set amount_paisa = pending_amount_paisa, override_status = 'approved', approved_by = auth.uid(), approved_at = now()
     where id = p_line_id;
  else
    update public.fee_plan_line
       set pending_amount_paisa = null, override_status = 'rejected', approved_by = auth.uid(), approved_at = now()
     where id = p_line_id;
  end if;
end;
$$;

revoke execute on function public.decide_fee_plan_override(uuid, boolean) from public, anon;
grant execute on function public.decide_fee_plan_override(uuid, boolean) to authenticated;

create or replace function public.remove_fee_plan_line(p_line_id uuid, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select fp.tenant_id into v_tenant_id
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.fee_plan_line
     set effective_to = (date_trunc('month', current_date) + interval '1 month - 1 day')::date
   where id = p_line_id and effective_to is null;
  if not found then
    raise exception 'ALREADY_REMOVED' using errcode = '55000';
  end if;
end;
$$;

revoke execute on function public.remove_fee_plan_line(uuid, text) from public, anon;
grant execute on function public.remove_fee_plan_line(uuid, text) to authenticated;

alter table public.fee_plan enable row level security;
alter table public.fee_plan_line enable row level security;

create policy fee_plan_campus_scope on public.fee_plan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_plan_line_read on public.fee_plan_line
  for select to authenticated
  using (
    plan_id in (
      select id from public.fee_plan
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
