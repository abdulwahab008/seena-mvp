-- pgTAP tests for FR-K09: bulk monthly challan generation.
begin;
select plan(32);

select public.provision_tenant('test-challan-gen-co', 'Challan Gen Co', 'owner@challangenco.test');
select id as tenant_id from public.tenant where slug = 'test-challan-gen-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as principal_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@challangenco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal One');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset

-- ── student a enrols before any fee structure exists — no fee_plan ever
--    gets built for it, which is exactly the NO_FEE_PLAN case ───────────

select public.create_student(:'campus_id'::uuid, 'Student A NoPlan', '2015-01-01'::date, 'male') as student_a_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_a_id'::uuid) as enrol_a_id \gset

-- ── now build and publish the structure: TUITION only, mandatory ───────

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);

select public.create_concession_scheme(
  'SIB20', 'Sibling 20%', 'بہن بھائی 20%', 'percentage', 20, array[:'tuition_id']::uuid[], p_approver_role => 'principal'
) as scheme_id \gset

-- ── student b: plan builds with TUITION, then gets an approved 20% award ──

select public.create_student(:'campus_id'::uuid, 'Student B Concession', '2015-01-01'::date, 'female') as student_b_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_b_id'::uuid) as enrol_b_id \gset
select public.request_concession_award(
  :'enrol_b_id'::uuid, :'scheme_id'::uuid, 20, '2026-08-01'::date, '2026-12-31'::date
) as award_b_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);
select public.decide_concession_award(:'award_b_id'::uuid, true);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── student c: plain plan, no concession ───────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Student C Plain', '2015-01-01'::date, 'male') as student_c_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_c_id'::uuid) as enrol_c_id \gset

-- ── student d: plan builds normally, then its TUITION line is torn out
--    directly (bypassing RLS) to simulate a mandatory-head coverage gap ──

select public.create_student(:'campus_id'::uuid, 'Student D Gap', '2015-01-01'::date, 'female') as student_d_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_d_id'::uuid) as enrol_d_id \gset
select public.fee_plan.id as plan_d_id from public.fee_plan where enrolment_id = :'enrol_d_id' \gset
reset role;
delete from public.fee_plan_line where plan_id = :'plan_d_id' and fee_head_id = :'tuition_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── student e: enrols, then withdraws before generation runs ──────────

select public.create_student(:'campus_id'::uuid, 'Student E Withdrawn', '2015-01-01'::date, 'male') as student_e_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_e_id'::uuid) as enrol_e_id \gset
select public.fn_change_student_status(:'student_e_id'::uuid, 'inactive'::public.student_status, 'other'::public.status_reason_code);

-- ── dry run: 2 billable (b, c), 2 failed (a, d), 0 written ─────────────

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, true) as dry_result \gset
select is((:'dry_result'::jsonb ->> 'generated')::int, 2, 'dry run: 2 enrolments are billable (B and C)');
select is((:'dry_result'::jsonb ->> 'failed')::int, 2, 'dry run: 2 enrolments fail (A has no plan, D has a coverage gap)');
select is((:'dry_result'::jsonb ->> 'skipped')::int, 0, 'dry run: nothing is skipped yet — no challans exist');
select is(
  (:'dry_result'::jsonb -> 'preview_by_class' ->> 'Class 1')::bigint,
  900000::bigint,
  'dry run preview totals PKR 4,000 net for B (concession applied) + PKR 5,000 for C = 900000 paisa'
);
select is((select count(*)::int from public.fee_challan), 0, 'dry run writes zero fee_challan rows');
select is((select count(*)::int from public.fee_challan_batch), 0, 'dry run writes no batch row at all');

-- ── real run ────────────────────────────────────────────────────────

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, false) as run1_result \gset
select is((:'run1_result'::jsonb ->> 'generated')::int, 2, 'real run: 2 challans generated');
select is((:'run1_result'::jsonb ->> 'failed')::int, 2, 'real run: 2 enrolments still recorded as failed');
select is((:'run1_result'::jsonb ->> 'skipped')::int, 0, 'real run: nothing skipped on the first pass');
select is((select count(*)::int from public.fee_challan), 2, 'exactly 2 challans exist after the first run');

select challan_no as challan_b_no, net_paisa as net_b, gross_paisa as gross_b, concession_paisa as conc_b
  from public.fee_challan where enrolment_id = :'enrol_b_id' \gset
select challan_no as challan_c_no, net_paisa as net_c
  from public.fee_challan where enrolment_id = :'enrol_c_id' \gset

select is(length(:'challan_b_no'), 12, 'the generated challan number is 12 digits, same shape as FR-K10');
select is(length(:'challan_c_no'), 12, 'student C''s challan number is also 12 digits');
select isnt(:'challan_b_no'::text, :'challan_c_no'::text, 'the two challans got distinct numbers');
select is(:'gross_b'::bigint, 500000::bigint, 'student B''s gross is the full TUITION line, undiscounted');
select is(:'conc_b'::bigint, 100000::bigint, 'student B''s 20% concession on a 500000-paisa line is 100000 paisa');
select is(:'net_b'::bigint, 400000::bigint, 'student B''s net payable is gross minus the concession');
select is(:'net_c'::bigint, 500000::bigint, 'student C, with no concession, owes the full 500000');
select is(
  (select count(*)::int from public.fee_challan_line where challan_id = (select id from public.fee_challan where enrolment_id = :'enrol_b_id')),
  1,
  'student B''s challan has exactly one line (TUITION)'
);

select generated_count, failed_count, skipped_count from public.fee_challan_batch order by started_at desc limit 1 \gset
select is(:'generated_count'::int, 2, 'the batch row itself records 2 generated');
select is(:'failed_count'::int, 2, 'the batch row records 2 failed');
select is(
  (select count(*)::int from public.fee_challan_batch_error where batch_id = (select id from public.fee_challan_batch order by started_at desc limit 1)),
  2,
  'two batch_error rows are written, one per failed enrolment'
);
select is(
  (select reason from public.fee_challan_batch_error where enrolment_id = :'enrol_a_id'),
  'NO_FEE_PLAN',
  'student A''s failure reason is that no fee plan was ever built for it'
);
select is(
  (select reason from public.fee_challan_batch_error where enrolment_id = :'enrol_d_id'),
  'MANDATORY_HEAD_COVERAGE_GAP: TUITION',
  'student D''s failure reason names the missing mandatory head'
);

select is(public.student_balance(:'enrol_b_id'::uuid), 400000::bigint, 'student B''s ledger balance nets the charge and the concession');
select is(public.student_balance(:'enrol_c_id'::uuid), 500000::bigint, 'student C''s ledger balance is the full charge');
select is(
  (select count(*)::int from public.fee_challan where enrolment_id = :'enrol_e_id'),
  0,
  'the withdrawn student (E) never gets a challan at all — excluded before the loop even considers it'
);

-- ── re-run for the same period: fully idempotent ───────────────────────

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, false) as run2_result \gset
select is((:'run2_result'::jsonb ->> 'generated')::int, 0, 're-run: 0 new challans generated');
select is((:'run2_result'::jsonb ->> 'skipped')::int, 2, 're-run: both existing challans are reported skipped');
select is((select count(*)::int from public.fee_challan), 2, 're-run leaves the fee_challan count unchanged at 2');
select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = :'enrol_b_id'),
  2,
  're-run posts no duplicate ledger rows — still just the original charge and concession entries'
);

-- ── access control ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.generate_challans(%L, %L, ''2026-08-01''::date, false)', :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a teacher cannot run challan generation'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
-- Since 20260731770000_security_definer_campus_scope_audit.sql, the
-- app.auth_campus_ids() scope check runs before the CAMPUS_NOT_FOUND
-- existence check (same order as every other scope-checked function in
-- the schema) — so for this accountant, scoped to :campus_id only, a
-- random unknown campus id is rejected as FORBIDDEN (it can never be in
-- their own scope), not CAMPUS_NOT_FOUND. CAMPUS_NOT_FOUND is still
-- reachable for a campus id that IS in scope (or for an owner/super_admin,
-- who are exempt from the scope check) but doesn't exist in the tenant —
-- not re-tested here since that existence check itself is unchanged.
select throws_ok(
  format('select public.generate_challans(%L, %L, ''2026-08-01''::date, false)', gen_random_uuid(), :'session_id'),
  'FORBIDDEN',
  'an unknown campus id outside this accountant''s own scope is rejected as FORBIDDEN, not CAMPUS_NOT_FOUND'
);

select * from finish();
rollback;
