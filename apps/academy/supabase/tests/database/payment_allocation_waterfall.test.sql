-- pgTAP tests for FR-K16: partial payment and allocation waterfall.
--
-- Concurrency (two payments/credit-applications racing the same
-- enrolment's advisory lock) is not exercised here — pgTAP runs
-- single-connection, the same limitation already noted for every other
-- advisory-lock claim in this module (FR-K10's challan numbering,
-- FR-D11's leave balance hold). Only the sequential allocation math is
-- proven.
begin;
select plan(17);

select public.provision_tenant('test-payment-waterfall-co', 'Payment Waterfall Co', 'owner@paymentwaterfallco.test');
select id as tenant_id from public.tenant where slug = 'test-payment-waterfall-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

-- Billing periods are relative to current_date, not hardcoded 2026-07/
-- 08/09 — fee_plan.effective_from defaults to current_date and is set
-- the moment enrol_student() fires, so a hardcoded period before
-- "today" makes generate_challans() find zero applicable charges.
-- month1/month2/month3 preserve the original's 3-consecutive-month
-- relationship (month1 is always >= today, whatever today is).
select
  (date_trunc('month', current_date))::date as month1,
  (date_trunc('month', current_date) + interval '1 month')::date as month2,
  (date_trunc('month', current_date) + interval '2 months')::date as month3 \gset

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
select id as exam_id from public.fee_head where tenant_id = :'tenant_id' and code = 'EXAM' \gset

-- Both lines billed monthly (EXAM overridden from its quarterly default)
-- so a single billing period always produces a clean, predictable
-- two-head 800000-paisa challan (500000 TUITION + 300000 EXAM) to test
-- the waterfall against.
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'exam_id'::uuid, 300000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

-- EXAM settles before TUITION whenever a payment can't cover both.
select public.set_fee_head_priority(:'exam_id'::uuid, 1);
select public.set_fee_head_priority(:'tuition_id'::uuid, 2);

-- ── scenario A: an exact single-challan payment fully settles it ───────

select public.create_student(:'campus_id'::uuid, 'Exact Payer', '2015-01-01'::date, 'male') as exact_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'exact_student_id'::uuid) as exact_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'month2'::date, false) as gen_a \gset
select id as exact_challan_id from public.fee_challan where enrolment_id = :'exact_enrol_id' \gset

select public.record_payment(:'exact_enrol_id'::uuid, 800000::bigint, 'cash'::public.fee_payment_mode) as exact_payment_id \gset
select is(
  (select status::text from public.fee_challan where id = :'exact_challan_id'),
  'paid',
  'a payment exactly matching net_paisa marks the challan paid'
);
select is(
  (select count(*)::int from public.fee_payment_allocation where payment_id = :'exact_payment_id'),
  2,
  'the exact payment produces one allocation row per head (TUITION, EXAM)'
);
select is(
  public.student_balance(:'exact_enrol_id'::uuid),
  0::bigint,
  'the ledger balance is exactly zero after an exact payment'
);

-- ── scenario B: a payment spanning two challans settles the older one
--    fully, then applies the remainder to the newer one in priority order ─

select public.create_student(:'campus_id'::uuid, 'Waterfall Payer', '2015-01-01'::date, 'female') as wf_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'wf_student_id'::uuid) as wf_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'month1'::date, false);
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'month2'::date, false);
select id as wf_july_id from public.fee_challan where enrolment_id = :'wf_enrol_id' and billing_period = :'month1'::date \gset
select id as wf_august_id from public.fee_challan where enrolment_id = :'wf_enrol_id' and billing_period = :'month2'::date \gset

-- 1,000,000 against 800,000 (July) + 800,000 (August): July fully clears
-- (2 rows), then the 200,000 remainder goes to August's EXAM line only
-- (priority 1) — TUITION on August is untouched (1 row). 3 rows total.
select public.record_payment(:'wf_enrol_id'::uuid, 1000000::bigint, 'bank_challan'::public.fee_payment_mode) as wf_payment_id \gset
select is(
  (select count(*)::int from public.fee_payment_allocation where payment_id = :'wf_payment_id'),
  3,
  'AC: a payment spanning two challans writes 3 allocation rows'
);
select is(
  (select status::text from public.fee_challan where id = :'wf_july_id'),
  'paid',
  'the older (July) challan is fully paid first'
);
select is(
  (select status::text from public.fee_challan where id = :'wf_august_id'),
  'part_paid',
  'the newer (August) challan only receives the leftover, so it is merely part_paid'
);
select is(
  (select amount_paisa from public.fee_payment_allocation where payment_id = :'wf_payment_id' and challan_id = :'wf_august_id' and fee_head_id = :'exam_id'),
  200000::bigint,
  'AC: head priority is honoured — the higher-priority EXAM head on August absorbs the leftover, not TUITION'
);
select is(
  (select count(*)::int from public.fee_payment_allocation where payment_id = :'wf_payment_id' and challan_id = :'wf_august_id' and fee_head_id = :'tuition_id'),
  0,
  'the lower-priority TUITION head on August receives nothing — the leftover ran out first'
);
select is(
  public.student_balance(:'wf_enrol_id'::uuid),
  600000::bigint,
  '1,600,000 charged minus 1,000,000 paid leaves exactly 600,000 owed'
);

-- ── scenario C: an overpayment becomes advance credit and is applied
--    automatically to the next challan generated, with no new ledger row ─

select public.create_student(:'campus_id'::uuid, 'Credit Payer', '2015-01-01'::date, 'male') as credit_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'credit_student_id'::uuid) as credit_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'month2'::date, false);
select id as credit_august_id from public.fee_challan where enrolment_id = :'credit_enrol_id' \gset

select public.record_payment(:'credit_enrol_id'::uuid, 1200000::bigint, 'online'::public.fee_payment_mode) as credit_payment_id \gset
select is(
  (select status::text from public.fee_challan where id = :'credit_august_id'),
  'paid',
  'the overpaid challan is still marked fully paid'
);
select is(
  public.student_balance(:'credit_enrol_id'::uuid),
  -400000::bigint,
  'AC: the 400,000 excess shows as a negative (credit) balance — 1,200,000 paid against 800,000 owed'
);

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'month3'::date, false);
select id as credit_september_id from public.fee_challan where enrolment_id = :'credit_enrol_id' and billing_period = :'month3'::date \gset
select is(
  (select status::text from public.fee_challan where id = :'credit_september_id'),
  'part_paid',
  'AC: the credit is applied automatically the moment the next challan is generated'
);
select is(
  public.student_balance(:'credit_enrol_id'::uuid),
  400000::bigint,
  'applying the credit does not change the overall balance — it only links money already ledgered to the new charge (800,000 new debit minus the 400,000 credit already on the books)'
);
select is(
  (select count(*)::int from public.fee_payment where enrolment_id = :'credit_enrol_id'),
  1,
  'no second fee_payment row is created when the credit is applied — it is the same receipt, just linked further'
);
select is(
  (select count(*)::int from public.fee_payment_allocation where payment_id = :'credit_payment_id' and challan_id = :'credit_september_id'),
  2,
  -- 400,000 credit against September's EXAM (priority 1, needs 300,000)
  -- and TUITION (priority 2, needs 500,000): EXAM is fully covered
  -- (300,000) and the remaining 100,000 spills into TUITION — two
  -- allocation rows, same waterfall rule as any fresh payment.
  'the original payment now has allocation rows against both September heads the 400,000 credit reached'
);

-- ── access control and validation ───────────────────────────────────────

select throws_ok(
  format($$ select public.record_payment(%L, 0::bigint, 'cash'::public.fee_payment_mode) $$, :'exact_enrol_id'),
  'AMOUNT_MUST_BE_POSITIVE',
  'a zero or negative payment amount is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.record_payment(%L, 100000::bigint, 'cash'::public.fee_payment_mode) $$, :'exact_enrol_id'),
  'FORBIDDEN',
  'a class teacher cannot record a payment'
);

select * from finish();
rollback;
