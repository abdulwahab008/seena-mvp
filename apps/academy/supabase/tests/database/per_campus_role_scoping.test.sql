-- pgTAP tests for FR-A12: per-campus role scoping.
--
-- AC1 (a campus-scoped Principal never sees another campus's rows, in
-- counts either) and the propagation half of AC3 are proving pre-existing
-- infrastructure (student_campus_scope RLS from tenant_isolation_
-- hardening.sql; the claims_version epoch bump + assert_claims_fresh()
-- fail-closed check from 20260731750000_jwt_claim_epoch_and_fail_closed
-- .sql) rather than anything new — see this migration's own header for
-- why. AC2's "FORBIDDEN for an out-of-scope campus" and "All campuses"
-- assertions below exercise the actual fix in
-- 20260731760000_per_campus_role_scoping.sql. AC4 confirms the zero-
-- campus case for both a read (daily_collection_report) and a write
-- (finalise_cash_book_day).
begin;
select plan(20);

select public.provision_tenant('test-campus-scoping-co', 'Campus Scoping Co', 'owner@campusscoping.test');
select id as tenant_id from public.tenant where slug = 'test-campus-scoping-co' \gset
select id as campus1_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus 2', 'C2') returning id as campus2_id \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus 3', 'C3') returning id as campus3_id \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus 4', 'C4') returning id as campus4_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id', :'campus3_id', :'campus4_id')
  )::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';

select public.create_student(:'campus1_id'::uuid, 'Campus1 Student A', '2015-01-01'::date, 'male') as c1_student_a \gset
select public.create_student(:'campus1_id'::uuid, 'Campus1 Student B', '2015-01-01'::date, 'female') as c1_student_b \gset
select public.create_student(:'campus2_id'::uuid, 'Campus2 Student A', '2015-01-01'::date, 'male') as c2_student_a \gset

-- ── AC1: rows from other campuses are absent from results AND from any
--    count/aggregate ────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus1_id'))::text,
  true
);
select is(
  (select count(*)::int from public.student),
  2,
  'AC1: a principal scoped to campus1 only counts exactly campus1''s 2 students'
);
select is(
  (select count(*)::int from public.student where id = :'c2_student_a'),
  0,
  'AC1: campus2''s student is entirely absent, not merely excluded from a listing'
);
select ok(
  not exists (select 1 from public.student where campus_id = :'campus2_id'),
  'AC1: no row from campus2 leaks through, checked directly by campus_id'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'accountant',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id', :'campus3_id', :'campus4_id')
  )::text,
  true
);
select is(
  (select count(*)::int from public.student),
  3,
  'an accountant scoped to all 4 campuses counts all 3 seeded students across both campuses with data'
);

-- ── AC2 setup: real fee data in campus1 (500000 paisa) and campus2
--    (300000 paisa), same day, same shape as daily_collection_report
--    .test.sql's own fixture. create_section/create_draft_structure both
--    require owner/super_admin/principal (never accountant), so this
--    setup runs back under the tenant-wide owner claims set up top ──────

select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id', :'campus3_id', :'campus4_id')
  )::text,
  true
);

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select (current_date - 3) as pay_date \gset

select public.create_section(:'campus1_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as c1_section_id \gset
select public.create_draft_structure(:'campus1_id'::uuid, :'session_id'::uuid) as c1_structure_id \gset
select public.add_structure_line(:'c1_structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'c1_structure_id'::uuid);
select public.enrol_student(:'c1_section_id'::uuid, :'c1_student_a'::uuid) as c1_enrol_a \gset
select public.generate_challans(:'campus1_id'::uuid, :'session_id'::uuid, :'pay_date'::date, false);
select public.record_payment(:'c1_enrol_a'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode, null, :'pay_date'::date);

select public.create_section(:'campus2_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as c2_section_id \gset
select public.create_draft_structure(:'campus2_id'::uuid, :'session_id'::uuid) as c2_structure_id \gset
select public.add_structure_line(:'c2_structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 300000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'c2_structure_id'::uuid);
select public.enrol_student(:'c2_section_id'::uuid, :'c2_student_a'::uuid) as c2_enrol_a \gset
select public.generate_challans(:'campus2_id'::uuid, :'session_id'::uuid, :'pay_date'::date, false);
select public.record_payment(:'c2_enrol_a'::uuid, 300000::bigint, 'cash'::public.fee_payment_mode, null, :'pay_date'::date);

-- ── AC2: the fee dashboard's own RPCs enforce campus scope (the actual
--    gap this migration closes — none of the three previously checked
--    app.auth_campus_ids() at all) ──────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus1_id'))::text,
  true
);

select throws_ok(
  format('select public.build_collection_report_payload(%L, %L, %L)', :'pay_date', :'pay_date', :'campus2_id'),
  'FORBIDDEN',
  'AC2: a principal scoped to campus1 only cannot pull campus2''s collection report'
);
select is(
  (select count(*)::int from public.daily_collection_report(:'campus2_id'::uuid, :'pay_date'::date, :'pay_date'::date)),
  0,
  'AC2: daily_collection_report silently returns zero rows (not an error) for a campus outside the caller''s scope'
);
select throws_ok(
  format('select public.finalise_cash_book_day(%L, %L)', :'campus2_id', :'pay_date'),
  'FORBIDDEN',
  'AC2: a principal scoped to campus1 only cannot finalise campus2''s cash book'
);

select public.build_collection_report_payload(:'pay_date'::date, :'pay_date'::date, :'campus1_id'::uuid) as c1_payload \gset
select is(
  (:'c1_payload'::jsonb ->> 'grand_total_paisa')::bigint, 500000::bigint,
  'the principal can still pull their OWN campus''s report'
);

-- AC2 "All campuses": omitting p_campus_id aggregates across the CALLER'S
-- OWN scope, not the whole tenant.
select public.build_collection_report_payload(:'pay_date'::date, :'pay_date'::date) as c1_all_payload \gset
select is(
  (:'c1_all_payload'::jsonb ->> 'grand_total_paisa')::bigint, 500000::bigint,
  'AC2: "All campuses" for a principal scoped to only campus1 aggregates ONLY campus1, not campus2''s payment too'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'accountant',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id', :'campus3_id', :'campus4_id')
  )::text,
  true
);
select public.build_collection_report_payload(:'pay_date'::date, :'pay_date'::date) as all_payload \gset
select is(
  (:'all_payload'::jsonb ->> 'grand_total_paisa')::bigint, 800000::bigint,
  'AC2: "All campuses" for an accountant scoped to all 4 campuses sums campus1 + campus2''s payments (500000 + 300000)'
);
select ok(
  (:'all_payload'::jsonb -> 'campus_id') is null or (:'all_payload'::jsonb ->> 'campus_id') is null,
  'the aggregated payload carries a null campus_id, not a single campus''s id'
);

-- ── AC3: reducing a user's campus scope from 4 to 1 revokes access to
--    the removed campuses — proving the "remove" direction of the epoch
--    mechanism 20260731750000_jwt_claim_epoch_and_fail_closed.sql's own
--    test only proved for "add" ──────────────────────────────────────

reset role;
select gen_random_uuid() as staff_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'staff_user_id', 'reduced-accountant@campusscoping.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'staff_user_id', :'tenant_id', 'accountant', 'Reduced Accountant');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus1_id');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus2_id');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus3_id');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus4_id');

select claims_version as baseline_cv from public.app_user where user_id = :'staff_user_id' \gset

delete from public.user_campus
 where user_id = :'staff_user_id' and campus_id in (:'campus2_id', :'campus3_id', :'campus4_id');

select is(
  (select claims_version from public.app_user where user_id = :'staff_user_id'),
  :'baseline_cv'::int + 3,
  'AC3: removing 3 of 4 campus assignments bumps claims_version once per row removed (the trigger fires FOR EACH ROW)'
);

set local role authenticated;

-- The OLD (pre-reduction) token is rejected the instant it's used again —
-- synchronous, not a delayed/polled check, so well inside the AC's
-- 60-second bound.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'accountant', 'sub', :'staff_user_id',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id', :'campus3_id', :'campus4_id'),
    'cv', :'baseline_cv'::int
  )::text,
  true
);
select throws_ok(
  'select app.auth_tenant_id()',
  'TOKEN_EPOCH_STALE',
  'AC3: the stale (pre-reduction) token is rejected as soon as it''s used again after the reduction'
);
select throws_ok(
  format('select public.daily_collection_report(%L, %L, %L)', :'campus1_id', :'pay_date', :'pay_date'),
  'TOKEN_EPOCH_STALE',
  'AC3: the stale token can''t even read its OWN still-in-scope campus1 any more — the whole session is fenced, not just the removed campuses'
);

-- A FRESH token (matching cv, campus_ids reflecting only campus1) proves
-- the removed campuses are genuinely gone, not just epoch-blocked.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'accountant', 'sub', :'staff_user_id',
    'campus_ids', json_build_array(:'campus1_id'),
    'cv', :'baseline_cv'::int + 3
  )::text,
  true
);
select is(
  (select count(*)::int from public.daily_collection_report(:'campus2_id'::uuid, :'pay_date'::date, :'pay_date'::date)),
  0,
  'AC3: with a fresh, correctly-scoped token, campus2 is genuinely out of scope — zero rows, not an error'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus2_id'),
  0,
  'AC3: the reduced-scope user can no longer see campus2''s students either'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus1_id'),
  2,
  'AC3: campus1 (still in scope) is unaffected by the reduction'
);

-- ── AC4: a user with zero campuses in scope gets a "no campus assigned"
--    experience — no data endpoint returns rows, reads and writes alike ──

reset role;
delete from public.user_campus where user_id = :'staff_user_id' and campus_id = :'campus1_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'accountant', 'sub', :'staff_user_id',
    'campus_ids', '[]'::json,
    'cv', :'baseline_cv'::int + 4
  )::text,
  true
);
select is(
  (select count(*)::int from public.student),
  0,
  'AC4: a user with zero campuses in scope gets zero rows from student'
);
select is(
  (select count(*)::int from public.daily_collection_report(:'campus1_id'::uuid, :'pay_date'::date, :'pay_date'::date)),
  0,
  'AC4: zero campus scope also means zero rows from the fee dashboard''s report function'
);
select throws_ok(
  format('select public.finalise_cash_book_day(%L, %L)', :'campus1_id', :'pay_date'),
  'FORBIDDEN',
  'AC4: zero campus scope means even a write attempt (finalise) is refused outright, not silently no-op''d'
);

select * from finish();
rollback;
