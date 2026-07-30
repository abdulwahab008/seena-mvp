-- pgTAP tests for FR-K24: arrears carry-forward.
begin;
select plan(14);

select public.provision_tenant('test-arrears-co', 'Arrears Co', 'owner@arrearsco.test');
select id as tenant_id from public.tenant where slug = 'test-arrears-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session1_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session1_id'::uuid, :'class1_id'::uuid, 'A', 20) as section1_id \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

select public.create_draft_structure(:'campus_id'::uuid, :'session1_id'::uuid) as structure1_id \gset
select public.add_structure_line(:'structure1_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure1_id'::uuid);

-- ── same-session carry-forward: an unpaid July challan shows up as
--    August's arrears line ──────────────────────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Arrears Child', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'student_id'::uuid) as enrol_id \gset

select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, '2026-07-15'::date, false);
select id as july_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = '2026-07-01' \gset

-- July is left unpaid on purpose — its 500,000 net is what August's
-- arrears line should pick up.
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, '2026-08-15'::date, false);
select id as august_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = '2026-08-01' \gset

select is(
  (select arrears_paisa from public.fee_challan where id = :'august_id'),
  500000::bigint,
  'AC: August''s arrears line carries July''s unpaid 500,000'
);
select is(
  (select net_paisa from public.fee_challan where id = :'august_id'),
  1000000::bigint,
  'AC: net payable is arrears (500,000) plus this period''s own current charge (500,000)'
);
select is(
  (select gross_paisa from public.fee_challan where id = :'august_id'),
  500000::bigint,
  'gross_paisa (the current charge alone) is unaffected by arrears'
);

-- ── AC: paying August''s full net payable (which reaches back through the
--    waterfall to July, since arrears is never its own payable line)
--    settles both, and the NEXT challan then shows zero arrears ─────────

select public.record_payment(:'enrol_id'::uuid, 1000000::bigint, 'cash'::public.fee_payment_mode);
select is(
  (select status::text from public.fee_challan where id = :'july_id'),
  'paid',
  'AC: paying the full (arrears-inclusive) net payable settles the older July challan via the ordinary payment waterfall'
);
select is(
  (select status::text from public.fee_challan where id = :'august_id'),
  'paid',
  'AC: ...and August itself, using only the two challans'' own real charge lines — no phantom arrears line was needed'
);

select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, '2026-09-15'::date, false);
select id as september_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = '2026-09-01' \gset
select is(
  (select arrears_paisa from public.fee_challan where id = :'september_id'),
  0::bigint,
  'AC: arrears is 0 once everything owed going into this period has been paid'
);
select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = :'enrol_id' and entry_type = 'charge'),
  3,
  'exactly 3 charge entries exist (July, August, September) — arrears was never separately posted to the ledger'
);

-- ── cross-session carry-forward via link_enrolment_promotion ───────────

select public.create_academic_session(:'campus_id'::uuid, '2027', '2027-01-01'::date, '2027-12-31'::date) as session2_id \gset
select public.create_section(:'campus_id'::uuid, :'session2_id'::uuid, :'class1_id'::uuid, 'A', 20) as section2_id \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session2_id'::uuid) as structure2_id \gset
select public.add_structure_line(:'structure2_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure2_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Promoted Child', '2013-01-01'::date, 'female') as promoted_student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'promoted_student_id'::uuid) as old_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, '2026-07-15'::date, false);
-- Left unpaid: 500,000 owed on the old, prior-session enrolment.

select public.enrol_student(:'section2_id'::uuid, :'promoted_student_id'::uuid) as new_enrol_id \gset
select public.link_enrolment_promotion(:'new_enrol_id'::uuid, :'old_enrol_id'::uuid);

select public.generate_challans(:'campus_id'::uuid, :'session2_id'::uuid, '2027-01-15'::date, false);
select id as new_session_challan_id from public.fee_challan where enrolment_id = :'new_enrol_id' \gset
select is(
  (select arrears_paisa from public.fee_challan where id = :'new_session_challan_id'),
  500000::bigint,
  'AC: the first challan of the new session carries the prior (now-superseded) session enrolment''s 500,000 as arrears'
);
select is(
  (select net_paisa from public.fee_challan where id = :'new_session_challan_id'),
  1000000::bigint,
  'net payable in the new session is the carried-forward arrears plus the new session''s own current charge'
);

-- ── link_enrolment_promotion: validation ────────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Unrelated Child', '2014-01-01'::date, 'male') as other_student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'other_student_id'::uuid) as other_enrol_id \gset
select throws_ok(
  format('select public.link_enrolment_promotion(%L, %L)', :'other_enrol_id', :'old_enrol_id'),
  'STUDENT_MISMATCH',
  'link_enrolment_promotion() refuses two enrolments belonging to different students'
);
select throws_ok(
  format('select public.link_enrolment_promotion(%L, %L)', :'new_enrol_id', :'new_enrol_id'),
  'CANNOT_LINK_TO_SELF',
  'link_enrolment_promotion() refuses linking an enrolment to itself'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.link_enrolment_promotion(%L, %L)', :'new_enrol_id', :'old_enrol_id'),
  'FORBIDDEN',
  'a class teacher cannot link enrolments for arrears carry-forward'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── outstanding_balance_as_of / v_student_outstanding ───────────────────

select public.create_student(:'campus_id'::uuid, 'Balance Check Child', '2015-06-01'::date, 'male') as bal_student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'bal_student_id'::uuid) as bal_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, '2026-07-15'::date, false);
select is(
  public.outstanding_balance_as_of(:'bal_enrol_id'::uuid, clock_timestamp()),
  public.student_balance(:'bal_enrol_id'::uuid),
  'outstanding_balance_as_of() as of now matches student_balance() for an enrolment with no reversals'
);
select is(
  (select outstanding_paisa from public.v_student_outstanding where enrolment_id = :'bal_enrol_id'),
  500000::bigint,
  'v_student_outstanding reports the same 500,000 owed for the fresh, unpaid challan'
);

select * from finish();
rollback;
