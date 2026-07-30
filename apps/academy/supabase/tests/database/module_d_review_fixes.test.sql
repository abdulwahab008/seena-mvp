-- pgTAP tests for the Module D independent-review fixes
-- (20260731230000_module_d_review_fixes.sql).
begin;
select plan(14);

select public.provision_tenant('test-d-review-fix-co', 'D Review Fix Co', 'owner@dreviewfixco.test');
select id as tenant_id from public.tenant where slug = 'test-d-review-fix-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-d-review-fix-other-co', 'D Review Fix Other Co', 'owner@dreviewfixotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-d-review-fix-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select public.create_staff(:'other_campus_id'::uuid, 'Other Tenant Staff', 'female', p_cnic => '4210198760001') as other_staff_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as other_casual_id \gset
select public.fn_grant_leave_balance(:'other_staff_id'::uuid, :'other_casual_id'::uuid, 5.00);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_staff(:'campus_id'::uuid, 'Own Staff', 'male', p_cnic => '4210112340001') as own_staff_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'own_staff_id'::uuid, :'casual_id'::uuid, 5.00);

-- ── fix #1: mark_staff_attendance_bulk() rejects a foreign-tenant staff_id ─

select throws_ok(
  format(
    $$ select public.mark_staff_attendance_bulk(%L, current_date, jsonb_build_array(jsonb_build_object('staff_id', %L, 'status', 'present'))) $$,
    :'campus_id', :'other_staff_id'
  ),
  'STAFF_NOT_FOUND',
  'mark_staff_attendance_bulk() refuses a row whose staff_id belongs to a different tenant, protecting that tenant''s real attendance record'
);

-- ── fix #2: leave_ledger read policy is tenant-scoped ───────────────────
-- (as owner, only the own-tenant grant is visible, never the other tenant's)

select is(
  (select count(*)::int from public.leave_ledger where staff_id = :'other_staff_id'),
  0,
  'the leave_ledger RLS fix hides another tenant''s ledger rows even from an owner-role reader'
);
select is(
  (select count(*)::int from public.leave_ledger where staff_id = :'own_staff_id'),
  1,
  'the same owner can still see their own tenant''s ledger row'
);

-- ── fix #4: set_leave_approval_chain_step() rejects foreign ids ────────

select throws_ok(
  format('select public.set_leave_approval_chain_step(%L, %L, 1::smallint, ''hr_manager''::public.app_role)', :'other_campus_id', :'casual_id'),
  'CAMPUS_NOT_FOUND',
  'set_leave_approval_chain_step() refuses a campus_id belonging to a different tenant'
);
select throws_ok(
  format('select public.set_leave_approval_chain_step(%L, %L, 1::smallint, ''hr_manager''::public.app_role)', :'campus_id', :'other_casual_id'),
  'LEAVE_TYPE_NOT_FOUND',
  'set_leave_approval_chain_step() refuses a leave_type_id belonging to a different tenant'
);

-- ── fix #5: current_contract() now requires role + tenant ownership ────

select public.create_staff_contract(:'own_staff_id'::uuid, 'permanent', current_date) as contract_id \gset
select is(
  (public.current_contract(:'own_staff_id'::uuid)).id,
  :'contract_id'::uuid,
  'the fix does not regress an ordinary, authorized current_contract() call'
);
select throws_ok(
  format('select public.current_contract(%L)', :'other_staff_id'),
  'STAFF_NOT_FOUND',
  'current_contract() refuses a staff_id belonging to a different tenant'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.current_contract(%L)', :'own_staff_id'),
  'FORBIDDEN',
  'current_contract() now enforces the same role gate as the contract_hr_owner_only RLS policy it used to bypass'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── fix #6: fn_leave_balance()/eligible_leave_types() are tenant-scoped ─

select is(
  public.fn_leave_balance(:'other_staff_id'::uuid, :'other_casual_id'::uuid),
  0::numeric,
  'fn_leave_balance() returns 0, not another tenant''s real balance, for a foreign staff_id'
);
select is(
  (select count(*)::int from public.eligible_leave_types(:'other_staff_id'::uuid)),
  0,
  'eligible_leave_types() returns nothing for a foreign staff_id, not that tenant''s real catalogue'
);

-- ── fix #7: self-approval is refused in both decision paths ────────────

select gen_random_uuid() as own_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'own_user_id', 'ownstaff@dreviewfixco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'own_user_id', :'tenant_id', 'principal', 'Self Approving Principal');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.link_staff_user_account(:'own_staff_id'::uuid, :'own_user_id'::uuid);

select public.apply_for_leave(:'own_staff_id'::uuid, :'casual_id'::uuid, current_date + 10, current_date + 10, true) as self_app_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'own_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.fn_decide_leave_application(%L, 'approved') $$, :'self_app_id'),
  'CANNOT_DECIDE_OWN_APPLICATION',
  'fn_decide_leave_application() refuses to let a principal approve their own application'
);

-- ── fix #8: a half-day application must be a single date ───────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    $$ select public.apply_for_leave(%L, %L, current_date + 20, current_date + 21, true) $$,
    :'own_staff_id', :'casual_id'
  ),
  'HALF_DAY_MUST_BE_SINGLE_DATE',
  'apply_for_leave() rejects a half-day request spanning more than one date'
);

-- ── fix #9: attach_staff_campus() rejects a foreign-tenant campus_id ────

select throws_ok(
  format('select public.attach_staff_campus(%L, %L)', :'own_staff_id', :'other_campus_id'),
  'CAMPUS_NOT_FOUND',
  'attach_staff_campus() refuses a campus_id belonging to a different tenant'
);

-- ── sanity: the whole flow still works end to end ───────────────────────

select public.apply_for_leave(:'own_staff_id'::uuid, :'casual_id'::uuid, current_date + 30, current_date + 30, true) as final_app_id \gset
select public.fn_decide_leave_application(:'final_app_id'::uuid, 'approved');
select is(
  (select status from public.leave_application where id = :'final_app_id'),
  'approved'::public.leave_application_status,
  'the fixes do not regress an ordinary, authorized (non-self) approval'
);

select * from finish();
rollback;
