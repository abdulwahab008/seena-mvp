-- pgTAP tests for FR-K24: arrears carry-forward.
begin;
select plan(28);

select public.provision_tenant('test-arrears-co', 'Arrears Co', 'owner@arrearsco.test');
select id as tenant_id from public.tenant where slug = 'test-arrears-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session1_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset
select id as class8_id from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset

-- Billing periods are relative to current_date, not hardcoded 2026-07/
-- 08/09 — fee_plan.effective_from (supabase/migrations/20260731070000_
-- fee_plan.sql:50) defaults to current_date and is set the moment
-- enrol_student() fires its AFTER INSERT trigger, so any hardcoded
-- period before "today" makes generate_challans() find zero applicable
-- charges and skip instead of generating. period1 is pinned to "this
-- month" (always >= today, whatever today is), period2/period3 are the
-- next two consecutive months — the exact same 3-consecutive-month
-- relationship the original literals (2026-07/08/09) encoded.
select
  (date_trunc('month', current_date))::date as period1,
  (date_trunc('month', current_date) + interval '1 month')::date as period2,
  (date_trunc('month', current_date) + interval '2 months')::date as period3 \gset

-- The AC's 8,500-owed-from-July / 8,000-charged-in-August pair needs two
-- DIFFERENT amounts in two consecutive months off one snapshot plan, so
-- period1 carries an annual head billed in that month only (mask = just
-- period1's month bit) on top of the flat monthly tuition: July =
-- 800,000 + 50,000 = 850,000, August = 800,000.
select (1 << (extract(month from :'period1'::date)::int - 1))::int as annual_mask \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- Classes 7 and 8 stay active for the AC4 promotion (class 7 -> class 8);
-- every other level is deactivated so publish_fee_structure()'s mandatory
-- head coverage check only demands lines for the three in play.
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code not in ('1', '7', '8');
select public.create_section(:'campus_id'::uuid, :'session1_id'::uuid, :'class1_id'::uuid, 'A', 20) as section1_id \gset
select public.create_section(:'campus_id'::uuid, :'session1_id'::uuid, :'class7_id'::uuid, 'A', 20) as section7_id \gset

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select id as annual_id from public.fee_head where tenant_id = :'tenant_id' and code = 'ANNUAL' \gset

select public.create_draft_structure(:'campus_id'::uuid, :'session1_id'::uuid) as structure1_id \gset
select public.add_structure_line(:'structure1_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 800000::bigint, 'monthly'::public.fee_frequency);
select public.add_structure_line(
  :'structure1_id'::uuid, :'class1_id'::uuid, :'annual_id'::uuid, 50000::bigint, 'annual'::public.fee_frequency,
  null, :'annual_mask'::smallint
);
select public.add_structure_line(:'structure1_id'::uuid, :'class7_id'::uuid, :'tuition_id'::uuid, 1200000::bigint, 'monthly'::public.fee_frequency);
select public.add_structure_line(:'structure1_id'::uuid, :'class8_id'::uuid, :'tuition_id'::uuid, 800000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure1_id'::uuid);

-- ── AC1: an unpaid July balance of 8,500 PKR becomes August's arrears
--    line, on top of August's own fresh 8,000 PKR charge ────────────────

select public.create_student(:'campus_id'::uuid, 'Arrears Child', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'student_id'::uuid) as enrol_id \gset

select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period1'::date, false);
select id as july_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = :'period1'::date \gset

select is(
  (select net_paisa from public.fee_challan where id = :'july_id'),
  850000::bigint,
  'July is billed 8,500 PKR (800,000 tuition + 50,000 annual fund) and left unpaid'
);

select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period2'::date, false);
select id as august_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = :'period2'::date \gset

select is(
  (select arrears_paisa from public.fee_challan where id = :'august_id'),
  850000::bigint,
  'AC1: August''s arrears line carries July''s unpaid 850,000 paisa'
);
select is(
  (select gross_paisa - concession_paisa from public.fee_challan where id = :'august_id'),
  800000::bigint,
  'AC1: August''s own current charge is 800,000 paisa, unaffected by arrears'
);
select is(
  (select net_paisa from public.fee_challan where id = :'august_id'),
  1650000::bigint,
  'AC1: net payable is 1,650,000 paisa — one payment clears everything owed'
);

-- ── AC2: paying August''s full net payable (which reaches back through the
--    waterfall to July, since arrears is never its own payable line)
--    settles both, and the NEXT challan then shows zero arrears ─────────

select public.record_payment(:'enrol_id'::uuid, 1650000::bigint, 'cash'::public.fee_payment_mode);
select is(
  (select status::text from public.fee_challan where id = :'july_id'),
  'paid',
  'AC2: paying the full (arrears-inclusive) net payable settles the older July challan via the ordinary payment waterfall'
);
select is(
  (select status::text from public.fee_challan where id = :'august_id'),
  'paid',
  'AC2: ...and August itself, using only the two challans'' own real charge lines — no phantom arrears line was needed'
);

select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period3'::date, false);
select id as september_id from public.fee_challan where enrolment_id = :'enrol_id' and billing_period = :'period3'::date \gset
select is(
  (select arrears_paisa from public.fee_challan where id = :'september_id'),
  0::bigint,
  'AC2: arrears is 0 on September once August''s full challan has been paid'
);

-- ── AC3: arrears is a DISPLAY line derived from balance — summing the
--    ledger across all three challans must not count any charge twice ───

select is(
  (select count(*)::int from public.fee_ledger where enrolment_id = :'enrol_id' and entry_type = 'charge'),
  3,
  'AC3: exactly 3 charge entries exist (July, August, September) — arrears was never separately posted'
);
select is(
  (select coalesce(sum(amount_paisa), 0)::bigint from public.fee_ledger where enrolment_id = :'enrol_id' and direction = 'debit'),
  2450000::bigint,
  'AC3: total ledger debits are 850,000 + 800,000 + 800,000 — the 850,000 shown as August arrears is absent'
);
select is(
  (select coalesce(sum(amount_paisa), 0)::bigint from public.fee_ledger where enrolment_id = :'enrol_id' and direction = 'debit'),
  (select coalesce(sum(gross_paisa), 0)::bigint from public.fee_challan where enrolment_id = :'enrol_id'),
  'AC3: ledger debits equal the sum of the challans'' OWN charges, never their arrears-inflated net'
);
select is(
  (select count(*)::int from public.fee_challan_line fcl
     join public.fee_challan fc on fc.id = fcl.challan_id
    where fc.enrolment_id = :'enrol_id' and fcl.line_type = 'arrears'),
  0,
  'AC3: no payable challan line is ever written for arrears'
);
select is(
  public.student_balance(:'enrol_id'::uuid),
  800000::bigint,
  'AC3: the running balance after all three challans and one 1,650,000 payment is September''s charge alone'
);

-- ── partial payment: arrears is whatever is still owed, not the whole
--    original charge ────────────────────────────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Partial Payer', '2015-03-01'::date, 'female') as partial_student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'partial_student_id'::uuid) as partial_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period1'::date, false);
select public.record_payment(:'partial_enrol_id'::uuid, 300000::bigint, 'cash'::public.fee_payment_mode);
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period2'::date, false);
select id as partial_august_id from public.fee_challan where enrolment_id = :'partial_enrol_id' and billing_period = :'period2'::date \gset

select is(
  (select arrears_paisa from public.fee_challan where id = :'partial_august_id'),
  550000::bigint,
  'a 300,000 part payment against an 850,000 challan carries forward 550,000, not 850,000'
);
select is(
  (select net_paisa from public.fee_challan where id = :'partial_august_id'),
  1350000::bigint,
  'net payable after a part payment is the 550,000 remainder plus the new 800,000 charge'
);

-- ── AC4: a student promoted into a NEW session carries the old session''s
--    balance, and the challan says which session it came from ───────────

-- session2 is a full year after period1, not a hardcoded "2027" — same
-- reasoning as period1/2/3 above: it must stay >= current_date forever,
-- and "the year after period1's year" preserves the original's "new
-- academic session" relationship without ever going stale itself.
select (:'period1'::date + interval '1 year')::date as session2_start \gset
select (:'period1'::date + interval '1 year 1 month')::date as session2_period2 \gset
select (:'period1'::date + interval '2 years' - interval '1 day')::date as session2_end \gset
select extract(year from :'session2_start'::date)::text as session2_name \gset

select public.create_academic_session(:'campus_id'::uuid, :'session2_name', :'session2_start'::date, :'session2_end'::date) as session2_id \gset
select public.create_section(:'campus_id'::uuid, :'session2_id'::uuid, :'class8_id'::uuid, 'A', 20) as section8_id \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session2_id'::uuid) as structure2_id \gset
select public.add_structure_line(:'structure2_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 800000::bigint, 'monthly'::public.fee_frequency);
select public.add_structure_line(:'structure2_id'::uuid, :'class7_id'::uuid, :'tuition_id'::uuid, 1200000::bigint, 'monthly'::public.fee_frequency);
select public.add_structure_line(:'structure2_id'::uuid, :'class8_id'::uuid, :'tuition_id'::uuid, 800000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure2_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Promoted Child', '2013-01-01'::date, 'female') as promoted_student_id \gset
select public.enrol_student(:'section7_id'::uuid, :'promoted_student_id'::uuid) as old_enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period1'::date, false);
-- Left unpaid: 1,200,000 owed on the old, prior-session class 7 enrolment.

select public.enrol_student(:'section8_id'::uuid, :'promoted_student_id'::uuid) as new_enrol_id \gset
select public.link_enrolment_promotion(:'new_enrol_id'::uuid, :'old_enrol_id'::uuid);

select public.generate_challans(:'campus_id'::uuid, :'session2_id'::uuid, :'session2_start'::date, false);
select id as new_session_challan_id from public.fee_challan
 where enrolment_id = :'new_enrol_id' and billing_period = :'session2_start'::date \gset

select is(
  (select arrears_paisa from public.fee_challan where id = :'new_session_challan_id'),
  1200000::bigint,
  'AC4: the first challan of the new session carries the prior session enrolment''s 1,200,000 paisa as arrears'
);
select is(
  (select net_paisa from public.fee_challan where id = :'new_session_challan_id'),
  2000000::bigint,
  'AC4: net payable in the new session is the carried 1,200,000 plus class 8''s own 800,000'
);
select is(
  (select (arrears_source -> 0 ->> 'session_id')::uuid from public.fee_challan where id = :'new_session_challan_id'),
  :'session1_id'::uuid,
  'AC4: the arrears line references the prior session id it came from'
);
select is(
  (select (arrears_source -> 0 ->> 'amount_paisa')::bigint from public.fee_challan where id = :'new_session_challan_id'),
  1200000::bigint,
  'AC4: ...with the per-session amount that adds up to arrears_paisa'
);

-- ── the printed challan carries arrears, so its net payable reconciles ──

select public.build_challan_render_payload(:'new_session_challan_id'::uuid) as payload \gset
select is(
  (:'payload'::jsonb ->> 'arrears_paisa')::bigint,
  1200000::bigint,
  'build_challan_render_payload() exposes arrears_paisa, so net_paisa reconciles with what is printed'
);
select is(
  :'payload'::jsonb -> 'arrears_source' -> 0 ->> 'session_name',
  (select name from public.academic_session where id = :'session1_id'),
  'the printed arrears line names the session the money is carried from'
);

-- ── soft-deleted challans (FR-A15) must drop out of the balance ─────────

select public.soft_delete('enrolment', :'old_enrol_id');
select is(
  public.outstanding_balance_as_of(:'old_enrol_id'::uuid, clock_timestamp()),
  0::bigint,
  'soft-deleting an enrolment takes its challans'' charges out of the balance entirely'
);

select public.generate_challans(:'campus_id'::uuid, :'session2_id'::uuid, :'session2_period2'::date, false);
select is(
  (select arrears_paisa from public.fee_challan
    where enrolment_id = :'new_enrol_id' and billing_period = :'session2_period2'::date),
  800000::bigint,
  'a soft-deleted prior enrolment stops feeding the promotion chain — only the new enrolment''s own unpaid 800,000 carries'
);

-- ── link_enrolment_promotion: validation ────────────────────────────────

select public.create_student(:'campus_id'::uuid, 'Unrelated Child', '2014-01-01'::date, 'male') as other_student_id \gset
select public.enrol_student(:'section1_id'::uuid, :'other_student_id'::uuid) as other_enrol_id \gset
select throws_ok(
  format('select public.link_enrolment_promotion(%L, %L)', :'other_enrol_id', :'new_enrol_id'),
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
  format('select public.link_enrolment_promotion(%L, %L)', :'new_enrol_id', :'other_enrol_id'),
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
select public.generate_challans(:'campus_id'::uuid, :'session1_id'::uuid, :'period1'::date, false);
select is(
  public.outstanding_balance_as_of(:'bal_enrol_id'::uuid, clock_timestamp()),
  public.student_balance(:'bal_enrol_id'::uuid),
  'student_balance() is outstanding_balance_as_of() — one balance definition, not two that can drift'
);
select is(
  (select outstanding_paisa from public.v_student_outstanding where enrolment_id = :'bal_enrol_id'),
  850000::bigint,
  'v_student_outstanding reports the same 850,000 owed for the fresh, unpaid challan'
);
select is(
  public.outstanding_balance_as_of(:'bal_enrol_id'::uuid, now() - interval '1 day'),
  0::bigint,
  'as of a point before the charge was posted, nothing is owed'
);

select * from finish();
rollback;
