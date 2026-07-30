-- Module D (Staff & Leave) hardening — nine bugs found by an independent
-- second-pass review, none caught by this module's own pgTAP suite. Two
-- are RLS policies with no tenant filter at all — any admin-role user in
-- ANY tenant could read every other tenant's leave ledger and approval
-- data, zero UUID-guessing required. The rest are the same missing-
-- tenant-check-on-a-client-supplied-id shape already found and fixed in
-- Module C, plus a self-approval gap and a half-day date-range gap.

-- ── 1. mark_staff_attendance_bulk() never tenant-checked p_campus_id or
--    the staff_id inside each row of p_rows ─────────────────────────────
--
-- staff_attendance's own unique constraint is (staff_id, att_date) with
-- no tenant_id, so a caller supplying a foreign tenant's staff_id here
-- silently overwrites (via the ON CONFLICT) that tenant's real
-- attendance record, from inside this tenant's own transaction.

create or replace function public.mark_staff_attendance_bulk(p_campus_id uuid, p_date date, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row              jsonb;
  v_staff_id         uuid;
  v_status           public.attendance_status;
  v_remarks          text;
  v_existing_source  public.attendance_source;
  v_written_count    int := 0;
  v_locked_staff_ids uuid[] := '{}';
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A 7-day correction window for HR Manager; Principal/Owner/Super Admin
  -- are not bound by it. Every write either way lands in audit_log via
  -- the trigger above.
  if app.auth_role() = 'hr_manager' and p_date < current_date - 7 then
    raise exception 'CORRECTION_WINDOW_EXPIRED' using errcode = '23514';
  end if;

  -- One transaction, one RPC call for the whole campus — never one row
  -- per tap, or a flaky mobile connection leaves the register half
  -- written.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_staff_id := (v_row ->> 'staff_id')::uuid;
    v_status   := (v_row ->> 'status')::public.attendance_status;
    v_remarks  := v_row ->> 'remarks';

    if not exists (select 1 from public.staff where id = v_staff_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
    end if;

    select source into v_existing_source
      from public.staff_attendance
     where staff_id = v_staff_id and att_date = p_date;

    -- Source precedence: leave > biometric > manual. A clerk cannot mark
    -- an approved-leave teacher absent and trigger a wrong pay deduction
    -- — the row is skipped (not written), not silently overwritten, and
    -- reported back so the sheet UI can show which rows were locked.
    if v_existing_source = 'leave' and v_status not in ('on_leave', 'half_day') then
      v_locked_staff_ids := v_locked_staff_ids || v_staff_id;
      continue;
    end if;

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by, remarks)
    values (app.auth_tenant_id(), p_campus_id, v_staff_id, p_date, v_status, 'manual', auth.uid(), v_remarks)
    on conflict (staff_id, att_date) do update
       set status = excluded.status, source = 'manual', marked_by = excluded.marked_by, remarks = excluded.remarks, marked_at = now()
     where public.staff_attendance.source <> 'leave';

    v_written_count := v_written_count + 1;
  end loop;

  return jsonb_build_object('written', v_written_count, 'locked_staff_ids', to_jsonb(v_locked_staff_ids));
end;
$$;

-- ── 2. leave_ledger's own read policy had no tenant filter ─────────────
--
-- Any principal/hr_manager/owner/super_admin, in ANY tenant, doing
-- `supabase.from('leave_ledger').select('*')` got every tenant's entire
-- leave ledger — no UUID needed at all. Every sibling policy in this
-- module starts with `tenant_id = app.auth_tenant_id() and (...)`; this
-- one just never did.

drop policy leave_ledger_self_or_hr_read on public.leave_ledger;

create policy leave_ledger_self_or_hr_read on public.leave_ledger
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or exists (select 1 from public.staff s where s.id = leave_ledger.staff_id and s.user_id = auth.uid())
    )
  );

-- ── 3. leave_approval_step's own read policy had no tenant filter ──────
--
-- Same defect as #2. leave_approval_step has no tenant_id column of its
-- own, so the scope has to come through application_id's owning
-- leave_application. Without it, any admin-role user in any tenant, or
-- any user whose role happened to equal another tenant's configured
-- effective_approver_role, could read every tenant's approval-step rows
-- including approver comments.

drop policy approval_step_actor_or_hr_read on public.leave_approval_step;

create policy approval_step_actor_or_hr_read on public.leave_approval_step
  for select to authenticated
  using (
    application_id in (select id from public.leave_application where tenant_id = app.auth_tenant_id())
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager')
      or effective_approver_role::text = app.auth_role()
      or application_id in (
        select la.id from public.leave_application la
          join public.staff s on s.id = la.staff_id
         where s.user_id = auth.uid()
      )
    )
  );

-- ── 4. set_leave_approval_chain_step() never tenant-checked its ids ────
--
-- p_campus_id/p_leave_type_id fed straight into an INSERT ... ON
-- CONFLICT (campus_id, leave_type_id, step_no) — no tenant_id in that
-- constraint either. A caller who obtains another tenant's real
-- campus_id + leave_type_id (e.g. via findings #2/#3 above) could
-- silently rewrite that tenant's approval routing; apply_for_leave's and
-- advance_leave_approval's own chain lookups key off an already
-- tenant-verified staff/application row, so the corrupted row is exactly
-- what that tenant's genuine applicants would route through next.

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
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.leave_type where id = p_leave_type_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'LEAVE_TYPE_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.leave_approval_chain (tenant_id, campus_id, leave_type_id, step_no, approver_role, sla_hours)
  values (app.auth_tenant_id(), p_campus_id, p_leave_type_id, p_step_no, p_approver_role, p_sla_hours)
  on conflict (campus_id, leave_type_id, step_no) do update set approver_role = excluded.approver_role, sla_hours = excluded.sla_hours
  returning id into v_id;

  return v_id;
end;
$$;

-- ── 5. current_contract() had no role check and no tenant check at all ─
--
-- Granted straight to authenticated with neither guard, it directly
-- bypasses contract_hr_owner_only's RLS restriction (super_admin/owner/
-- hr_manager/principal only) — any authenticated user, any role, any
-- tenant, could pull any staff member's contract type/dates/notice
-- period. confirm_probation() in this same file shows the correct
-- pattern; current_contract() just never applied it.

create or replace function public.current_contract(p_staff_id uuid, p_on date default current_date)
returns public.staff_contract
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_contract  public.staff_contract;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_contract from public.staff_contract
   where staff_id = p_staff_id and start_date <= p_on and (end_date is null or end_date >= p_on)
   limit 1;

  return v_contract;
end;
$$;

-- ── 6. fn_leave_balance()/eligible_leave_types() never tenant/ownership-
--    checked their staff_id ────────────────────────────────────────────
--
-- fn_leave_balance() had no restriction at all. eligible_leave_types()
-- filtered leave_type by the TARGET staff's own tenant_id rather than
-- the CALLER's — given a foreign staff_id, it happily returned that
-- other tenant's leave-type catalogue.

create or replace function public.fn_leave_balance(p_staff_id uuid, p_leave_type_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(ll.days), 0)
    from public.leave_ledger ll
    join public.staff s on s.id = ll.staff_id
   where ll.staff_id = p_staff_id and ll.leave_type_id = p_leave_type_id
     and s.tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager') or s.user_id = auth.uid());
$$;

create or replace function public.eligible_leave_types(p_staff_id uuid)
returns setof public.leave_type
language sql
stable
security definer
set search_path = ''
as $$
  select lt.*
    from public.leave_type lt
    join public.staff s on s.id = p_staff_id
   where lt.tenant_id = s.tenant_id
     and s.tenant_id = app.auth_tenant_id()
     and lt.is_active
     and lt.eligible_genders @> array[s.gender::text]
     and lt.eligible_contract_types @> array[s.contract_type]
     and lt.effective_from = (
       select max(lt2.effective_from) from public.leave_type lt2
        where lt2.tenant_id = lt.tenant_id and lt2.code = lt.code and lt2.effective_from <= current_date
     );
$$;

-- ── 7. self-approval was possible in both decision paths ───────────────
--
-- Neither fn_decide_leave_application() (the single-step fallback) nor
-- advance_leave_approval() (the chain) ever compared the decider to the
-- applicant. The chain's own self-approval-skip rule
-- (app.fn_resolve_leave_approver_role) only redirects when the
-- applicant's role equals the CONFIGURED chain role — it does nothing
-- when the applicant is an Owner/Super Admin, since advance_leave_approval
-- exempts those two roles from the role match entirely. An Owner could
-- apply for their own leave and then approve it themselves.

create or replace function public.fn_decide_leave_application(
  p_application_id uuid, p_decision public.leave_application_status, p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.leave_application%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_DECISION' using errcode = '22023';
  end if;

  select * into v_app from public.leave_application
   where id = p_application_id and status = 'pending' and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;
  if exists (select 1 from public.staff where id = v_app.staff_id and user_id = auth.uid()) then
    raise exception 'CANNOT_DECIDE_OWN_APPLICATION' using errcode = '42501';
  end if;

  update public.leave_application
     set status = p_decision, decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
   where id = p_application_id;

  if p_decision = 'approved' then
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
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
  end if;
end;
$$;

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

  select * into v_app from public.leave_application
   where id = p_application_id and status = 'pending' and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;
  if exists (select 1 from public.staff where id = v_app.staff_id and user_id = auth.uid()) then
    raise exception 'CANNOT_DECIDE_OWN_APPLICATION' using errcode = '42501';
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

-- ── 8. apply_for_leave() didn't constrain the date range on a half-day
--    application ─────────────────────────────────────────────────────
--
-- p_is_half_day hardcoded the ledger hold to 0.5 days regardless of
-- p_from_date/p_to_date, but nothing rejected a multi-day range — a
-- direct RPC call could debit only 0.5 days while approval's own
-- generate_series(from_date, to_date, ...) would still write a
-- leave-sourced staff_attendance row for every day in the (unconstrained)
-- range. The UI already mirrors to_date to from_date client-side; this
-- makes the RPC — the actual gate — enforce it too.

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
  if p_is_half_day and p_to_date <> p_from_date then
    raise exception 'HALF_DAY_MUST_BE_SINGLE_DATE' using errcode = '23514';
  end if;

  select * into v_staff from public.staff where id = p_staff_id;
  if not found or v_staff.tenant_id <> app.auth_tenant_id() then
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

-- ── 9. attach_staff_campus() never tenant-checked p_campus_id ──────────
--
-- p_staff_id was already tenant-checked; p_campus_id was inserted into
-- staff_campus unchecked, letting a caller attach their own staff to a
-- foreign campus_id. Downstream reads stay tenant-safe (both
-- staff_campus policies re-derive tenant via campus/staff), so this is a
-- data-integrity gap rather than a direct leak — fixed for consistency
-- with create_staff, which validates the identical parameter.

create or replace function public.attach_staff_campus(p_staff_id uuid, p_campus_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.staff_campus (staff_id, campus_id) values (p_staff_id, p_campus_id) on conflict do nothing;
end;
$$;
