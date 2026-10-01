-- pgTAP tests for FR-K28: security deposit refund and no-dues clearance.
begin;
select plan(39);

select public.provision_tenant('test-nodues-co', 'No Dues Co', 'owner@nodues.test');
select id as tenant_id from public.tenant where slug = 'test-nodues-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-nodues-other', 'Other No Dues Co', 'owner@othernodues.test');
select id as other_tenant_id from public.tenant where slug = 'test-nodues-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as trans_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@nodues.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@nodues.test', 'authenticated', 'authenticated', 'x'),
  (:'owner_uid', 'o@nodues.test', 'authenticated', 'authenticated', 'x'), (:'lib_uid', 'l@nodues.test', 'authenticated', 'authenticated', 'x'),
  (:'trans_uid', 't@nodues.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'owner_uid', :'tenant_id', 'owner', 'Owner'),
  (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'), (:'trans_uid', :'tenant_id', 'transport_manager', 'Transport Manager');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as exam_id from public.fee_head where tenant_id = :'tenant_id' and code = 'EXAM' \gset
select public.create_student(:'campus_id'::uuid, 'Leaver One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Leaver Two', '2015-01-02'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.create_student(:'campus_id'::uuid, 'Leaver Three', '2015-01-03'::date, 'male') as s3 \gset
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid) as e3 \gset
select public.create_student(:'campus_id'::uuid, 'Leaver Four', '2015-01-04'::date, 'female') as s4 \gset
select public.enrol_student(:'section_id'::uuid, :'s4'::uuid) as e4 \gset
select public.create_student(:'campus_id'::uuid, 'Leaver Five', '2015-01-05'::date, 'male') as s5 \gset
select public.enrol_student(:'section_id'::uuid, :'s5'::uuid) as e5 \gset
select public.create_certificate_template('transfer'::public.certificate_type, 'Transfer Certificate',
  '<p>{{student.name_en}}, GR {{student.gr_number}}, left on {{enrolment.left_on}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>', null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_id'::uuid) as tpl \gset
select public.activate_certificate_template(:'tpl'::uuid) as _a \gset

-- ── AC1: a 2021 deposit is still held and is not revenue ──────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
reset role;
select count(*) as ledger_before from public.fee_ledger where tenant_id = :'tenant_id' \gset
select count(*) as payments_before from public.fee_payment where tenant_id = :'tenant_id' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_security_deposit(:'e1'::uuid, 500000::bigint, '2021-03-01'::date, 'cash', 'RCPT-2021-17') as dep1 \gset
select public.record_security_deposit(:'e2'::uuid, 500000::bigint, '2022-03-01'::date, 'cash');
select public.record_security_deposit(:'e3'::uuid, 500000::bigint, '2022-03-01'::date, 'cash');
select public.record_security_deposit(:'e4'::uuid, 500000::bigint, '2022-03-01'::date, 'cash');
select is(public.security_deposit_balance(:'e1'::uuid), 500000::bigint, 'AC1: the 2021 deposit still reads 500000 paisa held');
reset role;
select is((select count(*) from public.fee_ledger where tenant_id = :'tenant_id'), :'ledger_before'::bigint, 'AC1: receiving a deposit posts nothing to the fee ledger, so it cannot reach any revenue figure');
select is((select count(*) from public.fee_payment where tenant_id = :'tenant_id'), :'payments_before'::bigint, 'nor to the payments that collected-today figures are built from');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.record_security_deposit(%L, 100::bigint, current_date, 'cash') $$, :'e1'), 'DEPOSIT_ALREADY_HELD', 'a second held deposit for the same enrolment is refused');
select throws_ok(format($$ select public.record_security_deposit(%L, 0::bigint, current_date, 'cash') $$, :'e5'), 'AMOUNT_MUST_BE_POSITIVE', 'a zero deposit is refused');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.record_security_deposit(%L, 100::bigint, current_date, 'cash') $$, :'e5'), 'FORBIDDEN', 'a principal cannot record receipts');

-- ── AC2: a library fine blocks the refund and is offered for netting ──────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.build_no_dues_checklist(:'e1'::uuid) as c1 \gset
select is((select count(*) from public.no_dues_item where clearance_id = :'c1'::uuid), 5::bigint, 'the checklist covers fees, library, transport, hostel and inventory');
select is((select status from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'fees'), 'cleared', 'fees is cleared automatically when the ledger balance is zero');
select is(public.build_no_dues_checklist(:'e1'::uuid), :'c1'::uuid, 'building it again returns the same clearance');
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select id as lib_item from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'library' \gset
select id as trans_item from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'transport' \gset
select id as host_item from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'hostel' \gset
select id as inv_item from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'inventory' \gset
select id as fees_item from public.no_dues_item where clearance_id = :'c1'::uuid and domain = 'fees' \gset
select public.set_no_dues_item_outstanding(:'lib_item'::uuid, 30000::bigint, 'Lost reference book');
select throws_ok(format($$ select public.clear_no_dues_item(%L) $$, :'lib_item'), 'OUTSTANDING_AMOUNT_REMAINS', 'AC2: the library item stays pending while a fine is outstanding');
select throws_ok(format($$ select public.clear_no_dues_item(%L) $$, :'trans_item'), 'FORBIDDEN', 'a librarian cannot clear the transport item');
select throws_ok(format($$ select public.set_no_dues_item_outstanding(%L, 1::bigint) $$, :'fees_item'), 'FORBIDDEN', 'nor touch the fees item');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.approve_deposit_refund(%L) $$, :'e1'), 'NO_DUES_NOT_CLEARED', 'AC2: deposit refund approval is blocked while the library is pending');
select throws_ok(format($$ select public.set_no_dues_item_outstanding(%L, 1::bigint) $$, :'fees_item'), 'FEES_ITEM_IS_COMPUTED', 'fees dues come from the ledger, not from typing');
select public.clear_no_dues_item(:'host_item'::uuid);
select public.clear_no_dues_item(:'inv_item'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'trans_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.clear_no_dues_item(:'trans_item'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.net_no_dues_item_against_deposit(:'lib_item'::uuid), 30000::bigint, 'AC2: the 300 PKR fine is netted against the deposit');
select is(public.security_deposit_balance(:'e1'::uuid), 470000::bigint, 'leaving 4,700 held');
select is((select status from public.no_dues_clearance where id = :'c1'::uuid), 'cleared', 'with every item cleared the clearance closes');

-- ── AC3: approve and disburse ─────────────────────────────────────────────
select throws_ok(format($$ select public.approve_deposit_refund(%L) $$, :'e1'), 'FORBIDDEN', 'an accountant cannot approve the refund');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.approve_deposit_refund(:'e1'::uuid), 470000::bigint, 'the Principal approves a refund of 4,700 after the netted fine');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.disburse_deposit_refund(%L, 'cheque') $$, :'e1'), 'INSTRUMENT_REFERENCE_REQUIRED', 'a cheque needs its number');
select public.disburse_deposit_refund(:'e1'::uuid, 'cheque', 'CHQ-5521') as disb1 \gset
select is((:'disb1'::jsonb ->> 'ledger_balance_paisa')::bigint, 0::bigint, 'the student account nets to exactly 0 after the refund');
select is(public.security_deposit_balance(:'e1'::uuid), 0::bigint, 'AC3: the deposit liability is 0');
reset role;
select is((select amount_paisa || '/' || direction::text from public.fee_ledger where source_id = :'dep1'::uuid and entry_type = 'refund'), '470000/debit', 'AC3: the ledger carries a refund debit');
select is((select status from public.security_deposit where id = :'dep1'::uuid), 'refunded', 'and the deposit is marked refunded');

-- ── a clean clearance refunds the whole 5,000 ─────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.build_no_dues_checklist(:'e2'::uuid) as c2 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.clear_no_dues_item(id) from public.no_dues_item where clearance_id = :'c2'::uuid and status = 'pending' and domain in ('hostel', 'inventory', 'library', 'transport');
select is(public.approve_deposit_refund(:'e2'::uuid), 500000::bigint, 'AC3: with all five cleared the full 500000 is approved');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.disburse_deposit_refund(:'e2'::uuid, 'cash');
reset role;
select is((select amount_paisa from public.fee_ledger where enrolment_id = :'e2'::uuid and entry_type = 'refund' and direction = 'debit'), 500000::bigint, 'AC3: the refund debit is 500000 paisa');

-- ── fee dues are netted against the deposit and settle on the ledger ──────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_ledger_entry(:'e3'::uuid, 'charge'::public.fee_ledger_entry_type, 400000::bigint, 'debit'::public.fee_ledger_direction, :'exam_id'::uuid, current_date, 'k28-test', null);
select public.build_no_dues_checklist(:'e3'::uuid) as c3 \gset
select is((select outstanding_paisa from public.no_dues_item where clearance_id = :'c3'::uuid and domain = 'fees'), 400000::bigint, 'the fees item shows the ledger dues');
select is(public.net_no_dues_item_against_deposit((select id from public.no_dues_item where clearance_id = :'c3'::uuid and domain = 'fees')), 400000::bigint, 'the dues are offered for netting against the deposit');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.clear_no_dues_item(id) from public.no_dues_item where clearance_id = :'c3'::uuid and status = 'pending';
select public.approve_deposit_refund(:'e3'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.disburse_deposit_refund(:'e3'::uuid, 'cash') ->> 'ledger_balance_paisa')::bigint, 0::bigint, 'netting the fees dues leaves the ledger at exactly 0 after a 1,000 refund');

-- ── AC4: owner override of an open clearance releases the TC ──────────────
select public.build_no_dues_checklist(:'e4'::uuid) as c4 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_transfer_certificate(%L, current_date, 'Relocation') $$, :'e4'), 'NO_DUES_CLEARANCE_REQUIRED', 'an open clearance blocks the Transfer Certificate');
select throws_ok(format($$ select public.override_no_dues_clearance(%L, 'too short') $$, :'c4'), 'REASON_MIN_LENGTH_20', 'AC4: an override needs a reason of at least 20 characters');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.override_no_dues_clearance(%L, 'Family hardship, approved by board') $$, :'c4'), 'FORBIDDEN', 'only the Owner can override');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.override_no_dues_clearance(:'c4'::uuid, 'Family hardship, approved by the board');
select lives_ok(format($$ select public.issue_transfer_certificate(%L, current_date, 'Relocation') $$, :'e4'), 'AC4: after the Owner override the Transfer Certificate is issued');
reset role;
select is((select override_by from public.no_dues_clearance where id = :'c4'::uuid), :'owner_uid'::uuid, 'AC4: the overrider is recorded');
select is((select count(*) from public.audit_log where table_name = 'no_dues_clearance' and row_id = :'c4'::uuid and after ->> 'status' = 'overridden'), 1::bigint, 'AC4: the override is in the audit log with reason and timestamp');

-- ── tenant policy: no clearance at all can also block the TC ──────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.set_tc_requires_no_dues(true) $$), 'the Owner can require a clearance for every Transfer Certificate');
select throws_ok(format($$ select public.issue_transfer_certificate(%L, current_date, 'Relocation') $$, :'e5'), 'NO_DUES_CLEARANCE_REQUIRED', 'then a TC without any clearance is blocked');

-- ── isolation ─────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.security_deposit), 0::bigint, 'another school sees none of these deposits');
select throws_ok(format($$ select public.build_no_dues_checklist(%L) $$, :'e5'), 'ENROLMENT_NOT_FOUND', 'and cannot open a clearance for this school''s student');

select * from finish();
rollback;
