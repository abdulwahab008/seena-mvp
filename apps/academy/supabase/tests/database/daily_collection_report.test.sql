-- pgTAP tests for FR-K29: daily collection report and cash-book.
begin;
select plan(16);

select public.provision_tenant('test-collection-report-co', 'Collection Report Co', 'owner@collectionreportco.test');
select id as tenant_id from public.tenant where slug = 'test-collection-report-co' \gset
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
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

-- Three students, three challans, three payments on the same day split
-- across the three modes the AC itself uses. Dated 3 days before "today"
-- (rather than a fixed calendar date) so the reversal below — which
-- reverse_ledger_entry() always posts at the REAL current_date, never a
-- chosen/backdated one — is guaranteed to land strictly after it,
-- matching the AC's own "paid on the 12th, reversed on the 15th" order
-- regardless of what today actually is when this test runs.
select (current_date - 3) as pay_date \gset

select public.create_student(:'campus_id'::uuid, 'Cash Payer', '2015-01-01'::date, 'male') as cash_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'cash_student_id'::uuid) as cash_enrol_id \gset
select public.create_student(:'campus_id'::uuid, 'Bank Payer', '2015-01-01'::date, 'female') as bank_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'bank_student_id'::uuid) as bank_enrol_id \gset
select public.create_student(:'campus_id'::uuid, 'Online Payer', '2015-01-01'::date, 'male') as online_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'online_student_id'::uuid) as online_enrol_id \gset

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, :'pay_date'::date, false);

select public.record_payment(:'cash_enrol_id'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode, null, :'pay_date'::date);
select public.record_payment(:'bank_enrol_id'::uuid, 500000::bigint, 'bank_challan'::public.fee_payment_mode, null, :'pay_date'::date);
select public.record_payment(:'online_enrol_id'::uuid, 500000::bigint, 'online'::public.fee_payment_mode, null, :'pay_date'::date);

-- ── AC: the report ties exactly to the ledger, and mode subtotals sum to
--    the grand total with no residual bucket ──────────────────────────

select coalesce(sum(amount_paisa), 0)::bigint as report_total
  from public.daily_collection_report(:'campus_id'::uuid, :'pay_date'::date, :'pay_date'::date) \gset
select is(:'report_total'::bigint, 1500000::bigint, 'AC: the grand total equals SUM(amount_paisa) of the day''s payment credits');
select is(
  (select sum(amount_paisa)::bigint from public.fee_ledger where campus_id = :'campus_id' and entry_type = 'payment' and value_date = :'pay_date'::date),
  1500000::bigint,
  'the report total ties exactly to the ledger''s own payment credits for that value_date'
);
select is(
  (select count(*)::int from public.daily_collection_report(:'campus_id'::uuid, :'pay_date'::date, :'pay_date'::date)),
  3,
  'AC: three mode subtotals (cash, bank_challan, online) — one row per mode, no residual bucket'
);

select public.build_collection_report_payload(:'campus_id'::uuid, :'pay_date'::date, :'pay_date'::date) as payload \gset
select is((:'payload'::jsonb ->> 'grand_total_paisa')::bigint, 1500000::bigint, 'the payload''s grand_total_paisa matches the report function''s own total');
select is(
  (
    select coalesce(sum((v ->> 'amount_paisa')::bigint), 0)::bigint
      from jsonb_each(:'payload'::jsonb -> 'by_day' -> 0 -> 'by_mode') as t(k, v)
  ),
  1500000::bigint,
  'AC: the three mode subtotals inside the payload sum to the day total with no residual bucket'
);

-- ── AC: a reversal on a later date never rewrites the original day's
--    report — it shows up in ITS OWN day instead ──────────────────────

select id as cash_ledger_id from public.fee_ledger
  where enrolment_id = :'cash_enrol_id' and entry_type = 'payment' and value_date = :'pay_date'::date \gset

select public.reverse_ledger_entry(:'cash_ledger_id'::uuid, 'reversed for FR-K29 pgTAP coverage');

select coalesce(sum(amount_paisa), 0)::bigint as report_total_after_reversal
  from public.daily_collection_report(:'campus_id'::uuid, :'pay_date'::date, :'pay_date'::date) \gset
select is(
  :'report_total_after_reversal'::bigint, 1500000::bigint,
  'AC: regenerating the original day''s report after a later reversal still shows the ORIGINAL total, unchanged'
);
select is(
  (select count(*)::int from public.fee_ledger where campus_id = :'campus_id' and entry_type = 'reversal' and value_date = current_date),
  1,
  'AC: the reversal itself appears, dated today (reverse_ledger_entry always uses current_date, never backdated)'
);

-- ── cash_book_day: finalising computes opening/receipts/disbursements/
--    closing, and refuses to run twice for the same day ───────────────

select public.finalise_cash_book_day(:'campus_id'::uuid, :'pay_date'::date) as cb_aug12 \gset
select is((:'cb_aug12'::public.cash_book_day).opening_paisa, 0::bigint, 'the first-ever finalised day for this campus opens at zero');
select is((:'cb_aug12'::public.cash_book_day).receipts_paisa, 1500000::bigint, 'receipts equal the day''s own payment total, unaffected by the later reversal');
select is((:'cb_aug12'::public.cash_book_day).closing_paisa, 1500000::bigint, 'closing = opening + receipts - disbursements, with no disbursements posted on the original day itself');

select throws_ok(
  format('select public.finalise_cash_book_day(%L, %L)', :'campus_id', :'pay_date'),
  'ALREADY_FINALISED',
  'AC: a signed-off day can never be re-finalised — the later reversal must not be allowed to rewrite it'
);

-- The reversal's OWN day (today) picks up the disbursement.
select public.finalise_cash_book_day(:'campus_id'::uuid, current_date) as cb_today \gset
select is(
  (:'cb_today'::public.cash_book_day).disbursements_paisa,
  500000::bigint,
  'the reversal is counted as a disbursement on the day it was actually posted, not the original payment''s day'
);
select is(
  (:'cb_today'::public.cash_book_day).opening_paisa,
  1500000::bigint,
  'today''s opening carries forward the original day''s closing balance'
);
select is(
  (:'cb_today'::public.cash_book_day).closing_paisa,
  1000000::bigint,
  'closing correctly nets the carried-forward opening against today''s disbursement'
);

-- ── access control ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.finalise_cash_book_day(%L, %L)', :'campus_id', '2026-08-20'),
  'FORBIDDEN',
  'a class teacher cannot finalise the cash book'
);
select throws_ok(
  format('select public.build_collection_report_payload(%L, %L, %L)', :'campus_id', :'pay_date', :'pay_date'),
  'FORBIDDEN',
  'a class teacher cannot pull the collection report either'
);

select * from finish();
rollback;
