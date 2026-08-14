-- pgTAP tests for 20260801060000_cross_campus_leave_balance_check.sql.
--
-- The defect: apply_for_leave() (FR-D11) authorizes by identity — a
-- staff member applying for their own leave — and sizes the application
-- with working_days_between(v_staff.campus_id, ...), which
-- 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for a campus outside the CALLER's campus_ids claim. So
-- for exactly the self-service applicant this FR exists for:
--
--   * `if v_working_days > v_balance` became `NULL > balance` = NULL, so
--     the INSUFFICIENT_BALANCE control silently did not fire;
--   * the insert then hit leave_application.working_days, which is NOT
--     NULL, and the applicant got a bare 23502 the UI cannot explain.
--
-- Both populations are covered: an applicant at a campus their claim
-- does not cover, and one with no user_campus row at all, whose claim is
-- '{}' — `not (campus = any('{}'))` is true for EVERY campus.
--
-- Every assertion below FAILS against the pre-fix function: the
-- over-balance applications raised a not-null violation instead of
-- INSUFFICIENT_BALANCE, and the legitimate ones raised it instead of
-- succeeding. Two leave types are used so the balance-control cases and
-- the sizing cases cannot consume each other's ledger.
begin;
select plan(11);

select public.provision_tenant('test-xcampus-leave-co', 'Cross Campus Leave Co', 'owner@xcampusleave.test');
select id as tenant_id from public.tenant where slug = 'test-xcampus-leave-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@xcampusleave.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Leave Owner');

-- Ms Nadia is posted at campus South; her own claim covers campus North
-- only, or nothing at all.
select gen_random_uuid() as nadia_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'nadia_uid', 'nadia@xcampusleave.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'nadia_uid', :'tenant_id', 'subject_teacher', 'Ms Nadia');

select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_uid', 'colleague@xcampusleave.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_uid', :'tenant_id', 'subject_teacher', 'A Colleague');

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);

select public.create_staff(:'campus_b_id'::uuid, 'Ms Nadia', 'female', p_cnic => '4210112345678') as nadia_staff_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.create_leave_type('ANNUAL', 'Annual Leave', 20) as annual_id \gset
select public.fn_grant_leave_balance(:'nadia_staff_id'::uuid, :'casual_id'::uuid, 3.00);
select public.fn_grant_leave_balance(:'nadia_staff_id'::uuid, :'annual_id'::uuid, 20.00);

-- The login behind the staff record. staff.user_id is nullable precisely
-- because HR enters the record before the account exists.
reset role;
update public.staff set user_id = :'nadia_uid' where id = :'nadia_staff_id';
set local role authenticated;

-- ── Ms Nadia, claim = campus North only, applying for her own leave ────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'nadia_uid')::text,
  true
);

-- 2026-06-01 to 06-04 is Mon-Thu: 4 working days against a 3.00 balance.
select throws_ok(
  format(
    $$ select public.apply_for_leave(%L, %L, '2026-06-01'::date, '2026-06-04'::date) $$,
    :'nadia_staff_id', :'casual_id'
  ),
  '23514',
  'INSUFFICIENT_BALANCE',
  'AC: the balance control fires again for a self-service applicant scoped to another campus — it was silently skipped by a NULL comparison'
);
select is(
  (select count(*)::int from public.leave_application where leave_type_id = :'casual_id'::uuid),
  0,
  'and the over-balance application created no row'
);

select public.apply_for_leave(:'nadia_staff_id'::uuid, :'annual_id'::uuid, '2026-06-01'::date, '2026-06-02'::date) as app_id \gset
select is(
  (select working_days from public.leave_application where id = :'app_id'),
  2.00,
  'AC: a 2-working-day application is sized correctly instead of dying on a not-null violation the UI cannot explain'
);
select is(
  public.fn_leave_balance(:'nadia_staff_id'::uuid, :'annual_id'::uuid),
  18.00,
  'and the ledger holds exactly those 2 days'
);

-- ── The same defect with no second campus in sight ─────────────────────
-- A staff member with no user_campus row claims '{}', which contains no
-- campus at all, so she could not apply for leave at her own campus.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(), 'sub', :'nadia_uid')::text,
  true
);
select public.apply_for_leave(:'nadia_staff_id'::uuid, :'annual_id'::uuid, '2026-06-08'::date, '2026-06-14'::date) as empty_claim_app_id \gset
select is(
  (select working_days from public.leave_application where id = :'empty_claim_app_id'),
  6.00,
  'an applicant whose campus_ids claim is empty can apply at her own campus, and Sunday 06-14 is still excluded from the count'
);
select throws_ok(
  format(
    $$ select public.apply_for_leave(%L, %L, '2026-06-15'::date, '2026-06-18'::date) $$,
    :'nadia_staff_id', :'casual_id'
  ),
  '23514',
  'INSUFFICIENT_BALANCE',
  'and the balance control fires for her too'
);

-- A half-day never reached the resolver, so it is the control that says
-- the fixture itself is sound.
select public.apply_for_leave(:'nadia_staff_id'::uuid, :'annual_id'::uuid, '2026-06-16'::date, '2026-06-16'::date, true) as half_id \gset
select is(
  (select working_days from public.leave_application where id = :'half_id'),
  0.50,
  'the half-day path, which never consulted the campus calendar, still holds exactly 0.50'
);

-- ── The function's own access rule did not widen ───────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'other_uid')::text,
  true
);
select throws_ok(
  format(
    $$ select public.apply_for_leave(%L, %L, '2026-06-22'::date, '2026-06-23'::date) $$,
    :'nadia_staff_id', :'annual_id'
  ),
  '42501',
  'FORBIDDEN',
  'a colleague still cannot apply for somebody else''s leave — even one whose claim DOES cover that campus'
);

-- ── The audit's guard still holds for ordinary, direct callers ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'nadia_uid')::text,
  true
);
select is(
  (select public.working_days_between(:'campus_b_id'::uuid, '2026-06-01'::date, '2026-06-04'::date)),
  null,
  'the campus guard is untouched: the SAME applicant calling working_days_between() directly for campus South still gets NULL'
);
select is(
  (select public.working_days_between(:'campus_a_id'::uuid, '2026-06-01'::date, '2026-06-04'::date)),
  4.00,
  'while her own claimed campus North still counts normally through the public function'
);
select throws_ok(
  format($$ select app.working_days_between_unscoped(%L::uuid, %L::uuid, '2026-06-01'::date, '2026-06-04'::date) $$, :'tenant_id', :'campus_b_id'),
  '42501',
  null,
  'authenticated cannot call the unscoped counter directly — the guard cannot be routed around'
);

select * from finish();
rollback;
