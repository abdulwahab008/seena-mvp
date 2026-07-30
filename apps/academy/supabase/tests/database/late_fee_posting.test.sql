-- pgTAP tests for FR-K13: automated late fee posting.
begin;
select plan(14);

select public.provision_tenant('test-late-post-co', 'Late Post Co', 'owner@latepostco.test');
select id as tenant_id from public.tenant where slug = 'test-late-post-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);

-- billing period 2026-07 -> due_date lands on 2026-08-10 (a Monday, no
-- holiday/Sunday shift), same as this batch's other AC-anchored tests.
select public.create_student(:'campus_id'::uuid, 'Student One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-07-01'::date, false) as gen1_result \gset
select id as challan1_id from public.fee_challan where enrolment_id = :'enrol1_id' \gset

select public.create_late_fee_rule(
  :'campus_id'::uuid, :'session_id'::uuid, 'per_day'::public.late_fee_basis,
  p_grace_days => 0, p_amount_paisa => 5000, p_effective_from => '2026-01-01'::date
) as rule1_id \gset

-- ── AC: "already carrying 150 PKR, job runs, exactly one row of 5000
--    paisa is written, total becomes 200 PKR" — modelled as two
--    consecutive nightly runs advancing the run date by a day ─────────

reset role;
select public.apply_late_fees('2026-08-13'::date) as run1_result \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select coalesce(sum(amount_paisa), 0)::bigint from public.fee_ledger where challan_id = :'challan1_id' and entry_type = 'late_fee'),
  15000::bigint,
  'night 1 (3 days late, no grace): PKR 150 posted'
);

reset role;
select public.apply_late_fees('2026-08-14'::date) as run2_result \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.fee_ledger where challan_id = :'challan1_id' and entry_type = 'late_fee' and amount_paisa = 5000),
  1,
  'AC: night 2 (4 days late) writes exactly one new row of 5000 paisa — the delta, not a fresh recompute'
);
select is(
  (select coalesce(sum(amount_paisa), 0)::bigint from public.fee_ledger where challan_id = :'challan1_id' and entry_type = 'late_fee'),
  20000::bigint,
  'AC: the posted total is now PKR 200 (150 + 50)'
);
select is(
  (select count(*)::int from public.fee_ledger where challan_id = :'challan1_id' and entry_type = 'late_fee'),
  2,
  'still exactly two late_fee rows total — the first is never rewritten, only a new delta is appended'
);

-- ── AC: the same run date, executed twice, writes zero additional rows ──

reset role;
select public.apply_late_fees('2026-08-14'::date) as run3_result \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.fee_ledger where challan_id = :'challan1_id' and entry_type = 'late_fee'),
  2,
  'AC: re-running the same run date posts 0 additional rows — the delta is already 0'
);

-- ── AC: a fully paid challan accrues nothing ───────────────────────────

select public.create_student(:'campus_id'::uuid, 'Student Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-07-01'::date, false) as gen2_result \gset
select id as challan2_id from public.fee_challan where enrolment_id = :'enrol2_id' \gset
reset role;
update public.fee_challan set status = 'paid' where id = :'challan2_id';
select public.apply_late_fees('2026-08-20'::date) as run4_result \gset

-- ── fee_job_run records each run — read as superuser: the table has no
--    authenticated-readable RLS policy at all, by design (see the
--    migration header), so these assertions stay under `reset role`. ───

select is(
  (select count(*)::int from public.fee_job_run where job_name = 'fees_apply_late_fee'),
  4,
  'one fee_job_run row was written per apply_late_fees() call'
);
select is(
  (select status from public.fee_job_run where run_date = '2026-08-14'::date order by started_at desc limit 1),
  'completed',
  'a completed run is marked completed'
);
select isnt(
  (select duration_ms from public.fee_job_run where run_date = '2026-08-14'::date order by started_at desc limit 1),
  null,
  'duration_ms is recorded'
);
select is(
  (select rows_written from public.fee_job_run where run_date = '2026-08-13'::date),
  1,
  'night 1''s job run recorded exactly 1 row written'
);
select is(
  (select rows_written from public.fee_job_run where run_date = '2026-08-20'::date),
  1,
  -- Not 0: challan1 is still unpaid and legitimately keeps accruing on
  -- 2026-08-20 too — this run's 1 row is challan1's further delta, not
  -- challan2's. challan2's own zero-accrual is asserted directly below
  -- against the ledger, which is the real proof for this AC.
  'this run still writes challan1''s continued accrual — challan2 (paid) contributes 0 of its own'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.fee_ledger where challan_id = :'challan2_id' and entry_type = 'late_fee'),
  0,
  'AC: a challan marked paid before the job runs accrues no late fee, even 10 days past due'
);

-- ── the FR-K12 refactor changed nothing about compute_late_fee()'s own
--    answers — same AC number as that batch's own test ────────────────

select is(
  public.compute_late_fee(:'challan1_id'::uuid, '2026-08-14'::date), 20000::bigint,
  'compute_late_fee() still returns the correct total after being refactored to share app.fn_compute_late_fee()'
);

-- ── access control ──────────────────────────────────────────────────

select throws_ok(
  format('select public.apply_late_fees(%L)', '2026-08-14'::date),
  'permission denied for function apply_late_fees',
  'an authenticated owner cannot call apply_late_fees directly — it is service_role only'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.apply_late_fees(%L)', '2026-08-14'::date),
  'permission denied for function apply_late_fees',
  'not even a super_admin app-role can call it — service_role is a different thing entirely'
);

select * from finish();
rollback;
