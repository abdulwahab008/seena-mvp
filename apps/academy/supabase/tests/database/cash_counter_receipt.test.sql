-- pgTAP tests for FR-K17: cash counter collection and receipt.
begin;
select plan(19);

-- ── amount_in_words: pure computation, no fixtures needed ──────────────

select is(public.amount_in_words(850000::bigint), 'Rupees Eight Thousand Five Hundred Only', 'AC: 8,500 PKR renders exactly as the AC''s own example');
select is(public.amount_in_words(0::bigint), 'Rupees Zero Only', 'zero renders without a stray empty part');
select is(public.amount_in_words(100000::bigint), 'Rupees One Thousand Only', 'an exact thousand has no trailing zero-hundred noise');
select is(public.amount_in_words(1234567800::bigint), 'Rupees One Crore Twenty Three Lakh Forty Five Thousand Six Hundred Seventy Eight Only', 'crore/lakh grouping (South Asian, not million/billion) is used');
select throws_ok(
  $$ select public.amount_in_words(-100::bigint) $$,
  'AMOUNT_MUST_BE_NONNEGATIVE',
  'a negative amount is rejected rather than silently rendered'
);

select public.provision_tenant('test-cash-counter-co', 'Cash Counter Co', 'owner@cashcounterco.test');
select id as tenant_id from public.tenant where slug = 'test-cash-counter-co' \gset
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

select public.create_student(:'campus_id'::uuid, 'Counter Child', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-15'::date, false);
select id as challan_id, challan_no from public.fee_challan where enrolment_id = :'enrol_id' \gset

-- ── AC: scanning the challan pre-fills student + net payable + outstanding ─

select public.lookup_challan_for_counter(:'challan_no') as lookup_result \gset
select is(
  (:'lookup_result'::jsonb ->> 'student_name'),
  'Counter Child',
  'AC: the barcode lookup resolves the student'
);
select is(
  (:'lookup_result'::jsonb ->> 'outstanding_paisa')::bigint,
  500000::bigint,
  'AC: the amount field pre-fill (outstanding_paisa) equals the untouched challan''s net payable'
);

-- ── AC: confirming the payment produces a receipt with a unique number,
--    and the ledger already carries the credit ────────────────────────

select public.collect_cash_payment(:'challan_id'::uuid, 500000::bigint, 'idem-key-001') as collect_result \gset
select is(
  ((:'collect_result'::jsonb ->> 'is_replay')::boolean),
  false,
  'the first collection is not a replay'
);
select id as receipt_id from public.fee_receipt where receipt_no = (:'collect_result'::jsonb ->> 'receipt_no') \gset
select isnt(:'receipt_id'::uuid, null::uuid, 'a receipt row exists under the returned receipt_no');
select is(
  (select status::text from public.fee_challan where id = :'challan_id'),
  'paid',
  'the challan is marked paid via the ordinary FR-K16 waterfall, same as any other payment'
);
select is(
  public.student_balance(:'enrol_id'::uuid),
  0::bigint,
  'the ledger already contains the credit row — balance is zero immediately after collection'
);

-- ── AC: a flaky-connection retry with the same idempotency key replays,
--    it does not double-charge ─────────────────────────────────────────

select public.collect_cash_payment(:'challan_id'::uuid, 500000::bigint, 'idem-key-001') as retry_result \gset
select is(
  ((:'retry_result'::jsonb ->> 'is_replay')::boolean),
  true,
  'AC: a retry under the same client idempotency key is recognised as a replay'
);
select is(
  (:'retry_result'::jsonb ->> 'receipt_id'),
  (:'collect_result'::jsonb ->> 'receipt_id'),
  'the replay returns the exact same receipt, not a new one'
);
select is(
  public.student_balance(:'enrol_id'::uuid),
  0::bigint,
  'AC: no duplicate payment was created — the balance is unchanged by the retry'
);
select is(
  (select count(*)::int from public.fee_payment where enrolment_id = :'enrol_id'),
  1,
  'exactly one fee_payment row exists despite two collect_cash_payment calls'
);

-- ── AC: printing twice watermarks the second as a duplicate and logs
--    both prints ──────────────────────────────────────────────────────

select public.print_receipt(:'receipt_id'::uuid) as first_print \gset
select is(((:'first_print'::jsonb ->> 'is_duplicate')::boolean), false, 'the first print is not flagged a duplicate');
select is((:'first_print'::jsonb ->> 'amount_words'), 'Rupees Five Thousand Only', 'the print payload carries amount-in-words, ready for a renderer');

select public.print_receipt(:'receipt_id'::uuid) as second_print \gset
select is(((:'second_print'::jsonb ->> 'is_duplicate')::boolean), true, 'AC: printing the same receipt a second time is watermarked DUPLICATE');
select is(
  (select count(*)::int from public.fee_receipt_print_log where receipt_id = :'receipt_id'),
  2,
  'AC: both the original print and the reprint are logged'
);

select * from finish();
rollback;
