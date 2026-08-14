-- Fix: apply_for_leave() (FR-D11) stopped enforcing its leave-balance
-- check, and then failed with a raw constraint violation instead.
--
-- The function authorizes by IDENTITY, deliberately not by campus:
--
--     if app.auth_role() not in ('super_admin','owner','principal','hr_manager')
--        and not exists (select 1 from public.staff
--                         where id = p_staff_id and user_id = auth.uid())
--     then raise FORBIDDEN
--
-- — self-service leave is the FR's central case. But it sizes the
-- application with working_days_between(v_staff.campus_id, ...), which
-- 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for a campus outside the CALLER's campus_ids claim. Two
-- things then go wrong in sequence:
--
--   1. `if v_working_days > v_balance` becomes `NULL > balance` = NULL,
--      which is not true, so the INSUFFICIENT_BALANCE guard silently
--      does not fire — the one check standing between an applicant and
--      more leave than they have;
--   2. the insert that follows puts NULL into leave_application.
--      working_days, which is `numeric(5,2) not null`, so the applicant
--      gets a bare 23502 not-null violation. actions.ts recognizes
--      neither that code nor its message, so a legitimate self-service
--      application dies as "Could not submit" with nothing to act on.
--
-- (1) is masked by (2) today — the row never lands, so no over-drawn
-- leave is actually recorded. That is luck, not design: the balance
-- check is the control, and it is not running. Any future caller that
-- supplies working_days itself, or any relaxation of that NOT NULL,
-- turns the silent skip into an over-drawn ledger hold.
--
-- Two populations reach it, and the second is the ordinary one: a staff
-- member at a campus their own claim does not cover, and one with no
-- user_campus row at all, whose claim is '{}'. `not (campus =
-- any('{}'))` is true for EVERY campus, so an invited teacher who has
-- never been attached to a campus row could not apply for leave at her
-- own campus at all. FR-F15's export fix (20260801030000) hit the
-- identical shape.
--
-- Fix shape, exactly as 20260801010000 / 20260801020000 /
-- 20260801030000 / 20260801040000 established: the counting logic moves
-- to an app.working_days_between_unscoped() that PostgREST does not
-- expose (config.toml exposes public and graphql_public only) and whose
-- EXECUTE is revoked from public, anon AND authenticated, so only a
-- postgres-owned SECURITY DEFINER function that has already run its own
-- access check can reach it; public.working_days_between() keeps the
-- audit's campus guard byte-for-byte for every ordinary caller,
-- including the leave screen that calls it directly to preview a range.
--
-- The tenant is passed explicitly rather than read from the claim, for
-- the reason 20260801040000 sets out in full: apply_for_leave() has
-- already loaded its staff row and refused unless
-- `v_staff.tenant_id = app.auth_tenant_id()`, so the tenant is known
-- from data the caller was granted, and the contract the revokes
-- enforce is that every caller passes a tenant it read off such a row —
-- never one the caller supplied.
--
-- Nothing about the disclosure surface widens: the count returned is
-- over the applicant's OWN campus calendar, for a range they supplied,
-- and it is a number this FR then writes onto their own application
-- row. The count cannot be NULL — `select count(*) from
-- generate_series(...)` always yields a number — so the balance check
-- can no longer be skipped by a three-valued comparison.
--
-- Not changed here, reported instead (same resolver, different caller,
-- and not this defect): compute_monthly_attendance_summary()
-- (FR-G07/FR-G08) also calls working_days_between(), on a p_campus_id
-- the CALLER supplies. It validates that campus against the tenant but
-- not against the claim, so a Principal asking for a summary of a campus
-- outside their claim gets working_days = NULL in the stored summary
-- rather than a refusal. That one is a caller-supplied campus, so the
-- guard is arguably doing its job and the fix belongs with a decision
-- about whether that function should refuse instead — not folded in
-- here.

create or replace function app.working_days_between_unscoped(p_tenant_id uuid, p_campus_id uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::numeric
    from generate_series(p_from, p_to, interval '1 day') as d(day)
   where extract(dow from d.day) <> 0 -- Sunday is the weekly off day
     and not exists (
       select 1 from public.holiday_calendar h
        where h.holiday_date = d.day::date
          and h.tenant_id = p_tenant_id
          and (h.campus_id = p_campus_id or h.campus_id is null)
     );
$$;

revoke execute on function app.working_days_between_unscoped(uuid, uuid, date, date) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: an out-of-scope campus
-- still resolves to NULL, silently, exactly as the audit left it.
create or replace function public.working_days_between(p_campus_id uuid, p_from date, p_to date)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else app.working_days_between_unscoped(app.auth_tenant_id(), p_campus_id, p_from, p_to)
  end;
$$;

revoke execute on function public.working_days_between(uuid, date, date) from public, anon;
grant execute on function public.working_days_between(uuid, date, date) to authenticated;

-- Byte-for-byte FR-D11's function (with FR-D-review-fixes' half-day
-- range constraint) apart from the one resolution: the working days are
-- counted over the APPLICANT's own campus calendar, in the tenant that
-- staff row belongs to, which this function's own access rule already
-- established the caller's right to.
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
    v_working_days := app.working_days_between_unscoped(v_staff.tenant_id, v_staff.campus_id, p_from_date, p_to_date);
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
