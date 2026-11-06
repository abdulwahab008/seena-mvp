-- pgTAP tests for FR-K18: cash counter shift open, close and physical tally.
begin;
select plan(17);

select public.provision_tenant('test-counter-shift-co', 'Counter Shift Co', 'owner@countershift.test');
select id as tenant_id from public.tenant where slug = 'test-counter-shift-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as principal_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@countershift.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@countershift.test', 'authenticated', 'authenticated', 'x'),
  (:'principal_uid', 'p@countershift.test', 'authenticated', 'authenticated', 'x'),
  (:'teacher_uid', 't@countershift.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Shift Owner'),
  (:'acct_uid', :'tenant_id', 'accountant', 'Shift Accountant'),
  (:'principal_uid', :'tenant_id', 'principal', 'Shift Principal'),
  (:'teacher_uid', :'tenant_id', 'class_teacher', 'Shift Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Shift Child', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select id as challan_id from public.fee_challan where enrolment_id = :'enrol_id' \gset

select public.create_cash_counter(:'campus_id'::uuid, 'Front desk') as counter_id \gset
select public.create_cash_counter(:'campus_id'::uuid, 'Back desk') as counter2_id \gset

-- ── AC: no open session, no cash receipt ─────────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select throws_ok(
  format($$ select public.collect_cash_payment(%L, 300000, 'shift-no-session') $$, :'challan_id'),
  '55000',
  'COUNTER_SESSION_REQUIRED: open a counter session first',
  'AC: a cash receipt without an open counter session is rejected'
);

-- ── session A: totals agree with the count, so it closes clean ───────────

select public.open_counter_session(:'counter_id'::uuid, 100000) as sess_a \gset
select public.collect_cash_payment(:'challan_id'::uuid, 200000, 'shift-a-1');
select public.collect_cash_payment(:'challan_id'::uuid, 100000, 'shift-a-2');

select public.counter_session_totals(:'sess_a'::uuid) as totals_a \gset
select is((:'totals_a'::jsonb ->> 'receipt_count')::int, 2, 'the running total counts both cash receipts');
select is((:'totals_a'::jsonb ->> 'cash_total_paisa')::bigint, 300000::bigint, 'the running total sums the cash collected');

select public.close_counter_session(:'sess_a'::uuid, '{"1000": 4}'::jsonb) as closed_a \gset
select is(:'closed_a'::jsonb ->> 'status', 'closed', 'AC: float 1,000 + receipts 3,000 against a 4,000 count closes cleanly');
select is((:'closed_a'::jsonb ->> 'variance_paisa')::bigint, 0::bigint, 'and records a zero variance');

-- ── AC: a closed session takes no late receipt ───────────────────────────

reset role;
select id as payment_id from public.fee_payment where enrolment_id = :'enrol_id' order by received_at limit 1 \gset
select throws_ok(
  format($$ insert into public.fee_receipt (tenant_id, campus_id, payment_id, receipt_no, counter_session_id) values (%L, %L, %L, 'RCP-LATE', %L) $$,
         :'tenant_id', :'campus_id', :'payment_id', :'sess_a'),
  '55000',
  'COUNTER_SESSION_CLOSED: record this receipt against a currently open session',
  'AC: a back-dated cash receipt against a closed session is rejected'
);
set local role authenticated;

-- ── session B: a short count within the threshold closes with variance ───

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.open_counter_session(:'counter_id'::uuid, 0) as sess_b \gset
select public.collect_cash_payment(:'challan_id'::uuid, 100000, 'shift-b-1');
select public.close_counter_session(:'sess_b'::uuid, '{"500": 1}'::jsonb) as closed_b \gset
select is(:'closed_b'::jsonb ->> 'status', 'closed_with_variance', 'AC: a 500 PKR shortfall is recorded and the session is closed_with_variance');
select is((:'closed_b'::jsonb ->> 'variance_paisa')::bigint, -50000::bigint, 'the variance is -50000 paisa, attributed to the person who closed it');

-- ── session C: a variance beyond the threshold needs a countersign ───────

select public.open_counter_session(:'counter_id'::uuid, 0) as sess_c \gset
select public.collect_cash_payment(:'challan_id'::uuid, 50000, 'shift-c-1');

select throws_ok(
  format($$ select public.open_counter_session(%L, 0) $$, :'counter2_id'),
  '23505',
  'COUNTER_SESSION_ALREADY_OPEN',
  'a person works one counter at a time at a campus'
);
select throws_ok(
  format($$ select public.close_counter_session(%L, '{"abc": 1}'::jsonb) $$, :'sess_c'),
  '23514',
  'DENOMINATIONS_INVALID',
  'a denomination that is not a whole number is refused'
);
select throws_ok(
  format($$ select public.close_counter_session(%L, '{"5000": 1}'::jsonb) $$, :'sess_c'),
  '55000',
  'COUNTERSIGN_REQUIRED',
  'AC: a variance beyond the threshold blocks closure until a principal countersigns'
);

select throws_ok(
  format($$ select public.countersign_counter_session(%L, 'ok') $$, :'sess_c'),
  '42501',
  'FORBIDDEN',
  'an accountant cannot countersign'
);

select set_config('request.jwt.claims', json_build_object('sub', :'principal_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(
  format($$ select public.countersign_counter_session(%L, 'ok') $$, :'sess_c'),
  '23514',
  'REMARK_TOO_SHORT',
  'a countersign needs a real remark'
);
select lives_ok(
  format($$ select public.countersign_counter_session(%L, 'Counted twice with the cashier, surplus is a late deposit') $$, :'sess_c'),
  'a principal countersigns with a remark'
);

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(
  format($$ select public.close_counter_session(%L, '{"5000": 1}'::jsonb) $$, :'sess_c'),
  'once countersigned, the shift closes'
);
select is(
  (select variance_paisa from public.cash_counter_session where id = :'sess_c'::uuid),
  450000::bigint,
  'and the variance is still recorded in full'
);

-- ── reads are for the people who handle fees ─────────────────────────────

select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.cash_counter_session), 0::bigint, 'a class teacher cannot read counter sessions');

select * from finish();
rollback;
