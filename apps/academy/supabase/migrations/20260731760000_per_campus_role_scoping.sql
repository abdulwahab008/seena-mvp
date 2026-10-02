-- FR-A12: per-campus role scoping.
--
-- What already existed before this migration: the whole enforcement
-- backbone. app.auth_campus_ids() (foundation.sql) reads campus_ids off
-- the JWT; campus-scoped RLS following the
-- `campus_id = any(app.auth_campus_ids())` (or the
-- `app.auth_role() in ('super_admin','owner') or campus_id = any(...)`
-- variant for owner/super_admin's tenant-wide bypass) shape already covers
-- ~60 tables/policies across the schema, including public.student
-- (student_campus_scope, tenant_isolation_hardening.sql) — so AC1
-- ("rows from other campuses are absent from results and from any
-- count/aggregate") already holds for students today, with zero changes
-- needed. AC3's propagation mechanism is also already fully built and
-- already tested: 20260731750000_jwt_claim_epoch_and_fail_closed.sql's
-- user_campus_bump_claims_version trigger bumps app_user.claims_version on
-- ANY user_campus insert/update/delete (so a scope reduction bumps the
-- epoch exactly like a scope grant does — that migration's own pgTAP
-- coverage proves the "add a campus" direction; this migration's test
-- adds the "remove a campus" direction), and app.auth_tenant_id() calls
-- app.assert_claims_fresh() before returning, which every campus-scoped
-- policy conjuncts with (100% of them, per a full grep across every
-- migration) — so a stale token is rejected the instant it's used again,
-- well inside the AC's 60-second bound.
--
-- What this migration actually closes:
--
-- 1. Three SECURITY DEFINER functions backing the fee dashboard
--    (daily_collection_report, build_collection_report_payload,
--    finalise_cash_book_day — 20260731280000_daily_collection_report.sql,
--    latest finalise_cash_book_day from
--    20260731290000_module_k_accounting_review_fixes.sql) never checked
--    `p_campus_id = any(app.auth_campus_ids())` at all — only role and
--    "campus exists in this tenant". SECURITY DEFINER functions run as
--    the function owner, not the caller, so they do not inherit the
--    caller's RLS; every other campus-scoped RPC in this codebase
--    (create_enquiry, create_section, create_staff, ...) carries this
--    check explicitly for exactly that reason. Without it, a Principal
--    scoped to campus GUL only could pass a DIFFERENT tenant campus's id
--    to these three functions and read (or, for finalise, WRITE) that
--    campus's fee data — a direct violation of this FR's "campus heads
--    cannot read each other's data" story. Fixed by adding the same
--    `app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id
--    = any(app.auth_campus_ids()))` guard already used everywhere else.
--
-- 2. build_collection_report_payload's p_campus_id now also accepts NULL,
--    meaning "aggregate across every campus the caller can see" (every
--    active campus in the tenant for super_admin/owner, else exactly
--    app.auth_campus_ids()) — this is what backs AC2's "All campuses"
--    filter option; a null-campus_id call was previously not a supported
--    input at all (it would have failed CAMPUS_NOT_FOUND).
--    daily_collection_report's p_campus_id stays required/non-null: it's
--    the lower-level per-campus building block build_collection_report_
--    payload itself calls, and it's exercised directly (with a concrete
--    campus id) by daily_collection_report.test.sql — only the FORBIDDEN
--    scope check is added there, no "all campuses" mode.
--
-- Not implemented — flagged, not silently skipped: there is no existing
-- product surface for an Owner to CHANGE an already-accepted staff
-- member's campus scope. user_campus rows today are created exactly once,
-- by accept_invitation(), from tenant_invitation.campus_ids at invite
-- time; no update/removal RPC exists, and app/(app)/staff/invite-form.tsx
-- only ever sends a single hardcoded campus id (invite_user's own
-- p_campus_ids uuid[] parameter already supports several — the UI just
-- never offers more than one). AC3's enforcement mechanism (epoch bump +
-- fail-closed stale-token rejection) is fully built and is proven directly
-- against public.user_campus in this migration's pgTAP test, the same way
-- upstream FR-A13's own test proves the "add a campus" direction — but
-- "an Owner reduces a Principal's scope from 4 campuses to 1 through the
-- product" has no UI/RPC to drive it yet. Building that staff-scope-
-- management screen is a distinct, unscoped feature (who can be
-- reassigned, how campuses are picked, etc.) and is out of this
-- migration's bounded gap-closing job — left as a follow-up.
--
-- Also flagged, not fixed (out of bounded scope, noted per this FR's own
-- brief rather than silently patched): a broader grep across every
-- SECURITY DEFINER function taking a p_campus_id argument turns up
-- several dozen more without an app.auth_campus_ids() check (e.g.
-- create_student, generate_challans, set_attendance_policy,
-- create_late_fee_rule). Some of those are legitimately owner/super_admin-
-- only operations that don't need the check; others may be genuine holes
-- like the three fixed here. Auditing and fixing all of them is a
-- separate, codebase-wide task, not this FR's job. Likewise, public.campus
-- itself has only a tenant-wide SELECT policy (campus_tenant_scope,
-- foundation.sql) with no campus_id-scoping — so campus-picker dropdowns
-- elsewhere in the app (new-student-form, staff invite, room creation,
-- ...) list every campus in the tenant regardless of the viewer's own
-- scope. That's a real, pre-existing UX/data-exposure inconsistency
-- spanning many pages; this migration works around it narrowly for the
-- one surface FR-A12's AC2 actually asks about (the fee dashboard, below)
-- by deriving campus options from user_campus/role instead of the raw
-- campus table, rather than widening campus_tenant_scope itself.

create or replace function public.daily_collection_report(p_campus_id uuid, p_from date, p_to date)
returns table (value_date date, mode public.fee_payment_mode, payment_count bigint, amount_paisa bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select vdc.value_date, vdc.mode, count(*)::bigint, sum(vdc.amount_paisa)::bigint
    from public.v_daily_collection vdc
   where vdc.tenant_id = app.auth_tenant_id()
     and vdc.campus_id = p_campus_id
     and vdc.value_date between p_from and p_to
     and (app.auth_role() in ('super_admin', 'owner', 'accountant', 'principal'))
     and (app.auth_role() in ('super_admin', 'owner') or p_campus_id = any(app.auth_campus_ids()))
   group by vdc.value_date, vdc.mode
   order by vdc.value_date, vdc.mode;
$$;

-- p_campus_id moves last and gains `default null`: a parameter with a
-- default must be trailing (a hard Postgres rule on the function's own
-- declaration, independent of how callers invoke it), and it needs a
-- default now so app code can omit it entirely for AC2's "All campuses"
-- option (an explicit `null` argument would work at the SQL level too,
-- but Supabase's generated TS types never widen a plain, non-defaulted
-- parameter's type to include `| null` — see this migration's header).
-- The old (uuid, date, date) overload is a different type signature, so
-- `create or replace` alone would leave it in place as an orphaned
-- second overload rather than replacing it — drop it explicitly first.
drop function if exists public.build_collection_report_payload(uuid, date, date);

create or replace function public.build_collection_report_payload(p_from date, p_to date, p_campus_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_by_day     jsonb;
  v_total      bigint;
  v_campus_ids uuid[];
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_campus_id is not null then
    if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
    v_campus_ids := array[p_campus_id];
  elsif app.auth_role() in ('super_admin', 'owner') then
    select coalesce(array_agg(id), '{}'::uuid[]) into v_campus_ids
      from public.campus where tenant_id = app.auth_tenant_id() and status = 'active';
  else
    v_campus_ids := app.auth_campus_ids();
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'value_date', d.value_date,
           'by_mode', d.by_mode,
           'day_total_paisa', d.day_total
         ) order by d.value_date), '[]'::jsonb)
    into v_by_day
    from (
      select mc.value_date,
             jsonb_object_agg(mc.mode, jsonb_build_object('count', mc.payment_count, 'amount_paisa', mc.amount_paisa)) as by_mode,
             sum(mc.amount_paisa) as day_total
        from (
          select value_date, mode, count(*) as payment_count, sum(amount_paisa) as amount_paisa
            from public.v_daily_collection
           where tenant_id = app.auth_tenant_id() and campus_id = any(v_campus_ids) and value_date between p_from and p_to
           group by value_date, mode
        ) mc
       group by mc.value_date
    ) d;

  select coalesce(sum(amount_paisa), 0) into v_total
    from public.v_daily_collection
   where tenant_id = app.auth_tenant_id() and campus_id = any(v_campus_ids) and value_date between p_from and p_to;

  return jsonb_build_object('campus_id', p_campus_id, 'from', p_from, 'to', p_to, 'grand_total_paisa', v_total, 'by_day', v_by_day);
end;
$$;

-- The dropped overload's grants went with it — reissue for the new
-- (date, date, uuid) signature.
revoke execute on function public.build_collection_report_payload(date, date, uuid) from public, anon;
grant execute on function public.build_collection_report_payload(date, date, uuid) to authenticated;

create or replace function public.finalise_cash_book_day(p_campus_id uuid, p_book_date date)
returns public.cash_book_day
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_opening       bigint;
  v_receipts      bigint;
  v_disbursements bigint;
  v_row           public.cash_book_day%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date = p_book_date) then
    raise exception 'ALREADY_FINALISED' using errcode = '55000';
  end if;
  if exists (select 1 from public.cash_book_day where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date > p_book_date) then
    raise exception 'CANNOT_FINALISE_BEFORE_A_LATER_FINALISED_DAY' using errcode = '55000';
  end if;

  select closing_paisa into v_opening
    from public.cash_book_day
   where tenant_id = v_tenant_id and campus_id = p_campus_id and book_date < p_book_date
   order by book_date desc
   limit 1;
  v_opening := coalesce(v_opening, 0);

  select coalesce(sum(amount_paisa), 0) into v_receipts
    from public.v_daily_collection
   where tenant_id = v_tenant_id and campus_id = p_campus_id and value_date = p_book_date;

  select coalesce(sum(fl.amount_paisa), 0) into v_disbursements
    from public.fee_ledger fl
   where fl.tenant_id = v_tenant_id and fl.campus_id = p_campus_id and fl.value_date = p_book_date
     and fl.entry_type = 'reversal'
     and exists (
       select 1 from public.fee_ledger orig
        where orig.id = fl.reversal_of_id and orig.entry_type = 'payment'
     );

  insert into public.cash_book_day (tenant_id, campus_id, book_date, opening_paisa, receipts_paisa, disbursements_paisa, closing_paisa, finalised_by)
  values (v_tenant_id, p_campus_id, p_book_date, v_opening, v_receipts, v_disbursements, v_opening + v_receipts - v_disbursements, auth.uid())
  returning * into v_row;

  return v_row;
end;
$$;
