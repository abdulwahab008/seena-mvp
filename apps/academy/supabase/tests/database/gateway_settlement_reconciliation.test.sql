-- pgTAP tests for FR-K23: gateway settlement reconciliation.
begin;
select plan(30);

select public.provision_tenant('test-gw-settle-co', 'Gateway Settle Co', 'owner@gwsettle.test');
select id as tenant_id from public.tenant where slug = 'test-gw-settle-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-gw-settle-other', 'Other Gateway Co', 'owner@othergw.test');
select id as other_tenant_id from public.tenant where slug = 'test-gw-settle-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@gwsettle.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@gwsettle.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@gwsettle.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 850000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Online Kid A', '2015-01-01'::date, 'male') as sa \gset
select public.enrol_student(:'section_id'::uuid, :'sa'::uuid) as ea \gset
select public.create_student(:'campus_id'::uuid, 'Online Kid B', '2015-01-02'::date, 'female') as sb \gset
select public.enrol_student(:'section_id'::uuid, :'sb'::uuid) as eb \gset
select public.create_student(:'campus_id'::uuid, 'Online Kid C', '2015-01-03'::date, 'male') as sc \gset
select public.enrol_student(:'section_id'::uuid, :'sc'::uuid) as ec \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', (now() at time zone 'Asia/Karachi')::date)::date + 14), false);
reset role;

select app.fn_post_online_payment(:'tenant_id'::uuid, :'ea'::uuid, 850000::bigint, 'GW-TXN-A') as pay_a \gset
select app.fn_post_online_payment(:'tenant_id'::uuid, :'eb'::uuid, 850000::bigint, 'GW-TXN-B') as pay_b \gset
select app.fn_post_online_payment(:'tenant_id'::uuid, :'ec'::uuid, 850000::bigint, 'GW-TXN-C') as pay_c \gset
update public.fee_payment set value_date = (now() at time zone 'Asia/Karachi')::date - 4 where id = :'pay_b'::uuid;
update public.fee_payment set value_date = (now() at time zone 'Asia/Karachi')::date - 2 where id = :'pay_c'::uuid;

-- ── AC1: 8,500 settled at 8,415 ───────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.start_gateway_settlement_import('jazzcash', repeat('a', 64), 'jc-settle-1.csv', 'gateway/x/1.csv') as imp1 \gset
select public.add_gateway_settlement_lines(:'imp1'::uuid, jsonb_build_array(
  jsonb_build_object('line_no', 2, 'gateway_txn_id', 'GW-TXN-A', 'settlement_date', (now() at time zone 'Asia/Karachi')::date, 'gross_paisa', 850000, 'commission_paisa', 8500, 'net_paisa', 841500, 'raw_line', 'a'),
  jsonb_build_object('line_no', 3, 'gateway_txn_id', 'GW-NOPE', 'settlement_date', (now() at time zone 'Asia/Karachi')::date, 'gross_paisa', 100000, 'commission_paisa', 1000, 'net_paisa', 99000, 'raw_line', 'b'),
  jsonb_build_object('line_no', 4, 'gateway_txn_id', null, 'settlement_date', null, 'gross_paisa', null, 'commission_paisa', null, 'net_paisa', null, 'raw_line', 'garbage', 'error', 'Amount is not a number')
), true);
select is((public.reconcile_gateway_settlement(:'imp1'::uuid) ->> 'matched')::int, 1, 'AC1: the 8,500 payment settled at 8,415 is matched');
reset role;
select is((select amount_paisa from public.gateway_commission where payment_id = :'pay_a'::uuid), 8500::bigint, 'AC1: a separate commission entry of 8,500 paisa exists');
select is((select coalesce(sum(case when direction = 'credit' then amount_paisa end), 0)::bigint from public.fee_ledger where enrolment_id = :'ea'::uuid and entry_type = 'payment'), 850000::bigint, 'AC1: the student ledger shows the full 850000 paisa credited');
select is(app.fn_enrolment_ledger_balance(:'ea'::uuid), 0::bigint, 'the commission leaves no shortfall on the student account');
select is((select status::text from public.fee_challan where enrolment_id = :'ea'::uuid), 'paid', 'AC1: the challan is fully paid');
select is((select count(*) from public.fee_ledger where enrolment_id = :'ea'::uuid and entry_type::text like '%commission%'), 0::bigint, 'and the commission never touches the student ledger');
select is((select status from public.gateway_settlement_line where import_id = :'imp1'::uuid and line_no = 3), 'unmatched', 'AC3: a settlement row with no matching payment is an unmatched exception');
select is((select status from public.gateway_settlement_line where import_id = :'imp1'::uuid and line_no = 4), 'parse_error', 'an unparseable row is kept with its raw text');
select is((select row_count || '/' || matched_count || '/' || exception_count from public.gateway_settlement_import where id = :'imp1'::uuid), '3/1/2', 'the import reports 3 rows, 1 matched, 2 exceptions');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.reconcile_gateway_settlement(:'imp1'::uuid) ->> 'matched')::int, 0, 'running reconciliation again changes nothing');
reset role;
select is((select count(*) from public.gateway_commission where tenant_id = :'tenant_id'), 1::bigint, 'and records no second commission');

-- ── AC4: duplicate file ───────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_like($$ select public.start_gateway_settlement_import('jazzcash', repeat('a', 64), 'again.csv', 'gateway/x/2.csv') $$, 'duplicate file (sha256 match%', 'AC4: re-uploading the same file is rejected');
select lives_ok($$ select public.start_gateway_settlement_import('easypaisa', repeat('a', 64), 'other-gw.csv', 'gateway/x/3.csv') $$, 'the same bytes from a different gateway are a different file');

-- ── gross mismatch, already settled, zero commission, bad arithmetic ──────
select public.start_gateway_settlement_import('jazzcash', repeat('b', 64), 'jc-settle-2.csv', 'gateway/x/4.csv') as imp2 \gset
select public.add_gateway_settlement_lines(:'imp2'::uuid, jsonb_build_array(
  jsonb_build_object('line_no', 2, 'gateway_txn_id', 'GW-TXN-A', 'settlement_date', (now() at time zone 'Asia/Karachi')::date, 'gross_paisa', 850000, 'commission_paisa', 8500, 'net_paisa', 841500, 'raw_line', 'a again'),
  jsonb_build_object('line_no', 3, 'gateway_txn_id', 'GW-TXN-B', 'settlement_date', (now() at time zone 'Asia/Karachi')::date, 'gross_paisa', 400000, 'commission_paisa', 4000, 'net_paisa', 396000, 'raw_line', 'b short'),
  jsonb_build_object('line_no', 4, 'gateway_txn_id', 'GW-TXN-C', 'settlement_date', (now() at time zone 'Asia/Karachi')::date, 'gross_paisa', 850000, 'commission_paisa', 0, 'net_paisa', 850000, 'raw_line', 'c free')
), true);
select public.reconcile_gateway_settlement(:'imp2'::uuid) as r2 \gset
select is((:'r2'::jsonb ->> 'exceptions')::int, 2, 'a re-settled payment and a gross mismatch are both exceptions');
select is((select error_text from public.gateway_settlement_line where import_id = :'imp2'::uuid and line_no = 2), 'This payment was already settled in an earlier file', 'the already-settled row says why');
select ok((select error_text like 'Settled gross 400000 differs%' from public.gateway_settlement_line where import_id = :'imp2'::uuid and line_no = 3), 'the mismatch row shows both amounts');
reset role;
select is((select count(*) from public.gateway_commission where payment_id = :'pay_c'::uuid), 0::bigint, 'a zero-commission settlement records no commission row');
select is((select status from public.gateway_settlement_line where payment_id = :'pay_c'::uuid), 'matched', 'but it still counts as settled');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.start_gateway_settlement_import('jazzcash', repeat('c', 64), 'jc-settle-3.csv', 'gateway/x/5.csv') as imp3 \gset
select throws_ok(format($$ select public.add_gateway_settlement_lines(%L, '[{"line_no":2,"gateway_txn_id":"X","settlement_date":"2026-01-01","gross_paisa":1000,"commission_paisa":10,"net_paisa":900,"raw_line":"x"}]'::jsonb) $$, :'imp3'), '23514', null, 'a row where gross is not commission plus net is refused by the database');

-- ── AC2: the unsettled watchdog ───────────────────────────────────────────
select is((select count(*) from public.v_unsettled_online_payments where payment_id = :'pay_b'::uuid), 1::bigint, 'AC2: a payment absent from settlement for 4 days is on the unsettled report');
select is((select age_days from public.v_unsettled_online_payments where payment_id = :'pay_b'::uuid), 4, 'AC2: with its age in days');
select is((select count(*) from public.v_unsettled_online_payments where payment_id = :'pay_a'::uuid), 0::bigint, 'a settled payment is not on it');
select is((select count(*) from public.v_unsettled_online_payments where tenant_id = :'tenant_id'), 1::bigint, 'the default threshold is 3 days, so the 2-day-old payment is not flagged');
select public.set_unsettled_after_days(1);
select is((select count(*) from public.v_unsettled_online_payments where tenant_id = :'tenant_id'), 1::bigint, 'with the threshold at 1 day the 2-day payment is flagged, but it is already settled');
select throws_ok($$ select public.set_unsettled_after_days(0) $$, 'DAYS_OUT_OF_RANGE', 'a zero-day threshold is refused');

-- ── access and isolation ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.start_gateway_settlement_import('onelink', repeat('d', 64), 'x.csv', 'gateway/x/6.csv') $$, 'FORBIDDEN', 'a teacher cannot import settlement files');
select is((select count(*) from public.gateway_settlement_line), 0::bigint, 'and cannot read them');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.reconcile_gateway_settlement(%L) $$, :'imp1'), 'FORBIDDEN', 'a principal can read but not reconcile');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'accountant', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.gateway_settlement_import), 0::bigint, 'another school sees none of these imports');
select throws_ok(format($$ select public.reconcile_gateway_settlement(%L) $$, :'imp1'), 'IMPORT_NOT_FOUND', 'and cannot reconcile them');

select * from finish();
rollback;
