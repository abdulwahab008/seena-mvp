-- pgTAP tests for FR-K20: bank reconciliation and exception queue.
begin;
select plan(26);

select public.provision_tenant('test-bank-recon-co', 'Bank Recon Co', 'owner@bankreconco.test');
select id as tenant_id from public.tenant where slug = 'test-bank-recon-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-bank-recon-other', 'Other Recon Co', 'owner@otherreconco.test');
select id as other_tenant_id from public.tenant where slug = 'test-bank-recon-other' \gset

select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'acct_uid', 'acct@bankreconco.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'acct_uid', :'tenant_id', 'accountant', 'Recon Accountant');
insert into public.campus_bank_account (campus_id, bank_name, title, account_no, iban) values (:'campus_id', 'HBL', 'Fees', '111', 'PK36HABB0000000000000111') returning id as bank_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select set_config('t.section', :'section_id', false);
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
create temp table recon_kid (n int primary key, enrol_id uuid, challan_id uuid, challan_no text);
grant all on recon_kid to authenticated;
do $$
declare
  i int; v_student uuid; v_enrol uuid;
begin
  for i in 1..12 loop
    v_student := public.create_student(current_setting('t.campus')::uuid, 'Recon Kid ' || i, '2015-01-01'::date, 'male');
    v_enrol := public.enrol_student(current_setting('t.section')::uuid, v_student);
    insert into recon_kid (n, enrol_id) values (i, v_enrol);
  end loop;
end $$;
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
reset role;
update recon_kid k set challan_id = c.id, challan_no = c.challan_no from public.fee_challan c where c.enrolment_id = k.enrol_id;

-- Kid 10 was paid in cash at the counter; kid 11's challan was cancelled.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment((select enrol_id from recon_kid where n = 10), 500000::bigint, 'cash'::public.fee_payment_mode, 'cash-k10');
reset role;
update public.fee_challan set status = 'cancelled' where id = (select challan_id from recon_kid where n = 11);

-- A challan number with a valid check digit that belongs to nobody, and one whose check digit is wrong.
select '00000000099' || public.challan_check_digit('00000000099')::text as ghost_ref \gset
select '00000000098' || ((public.challan_check_digit('00000000098') + 1) % 10)::text as bad_check_ref \gset

select gen_random_uuid() as dummy \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.start_bank_statement_import(:'bank_id'::uuid, repeat('f', 64), 'scroll.csv', 'p') as import_id \gset
select public.add_bank_statement_lines(:'import_id'::uuid, (
  select jsonb_agg(l order by (l ->> 'line_no')::int) from (
    select jsonb_build_object('line_no', k.n + 1, 'txn_date', '2026-08-12', 'challan_ref', k.challan_no,
             'amount_paisa', case k.n when 2 then 400000 else 500000 end, 'bank_ref', 'BK' || k.n, 'raw_line', 'r' || k.n) as l
      from recon_kid k where k.n <= 11
    union all select jsonb_build_object('line_no', 20, 'txn_date', '2026-08-12', 'challan_ref', :'ghost_ref', 'amount_paisa', 500000, 'bank_ref', 'BKG', 'raw_line', 'ghost')
    union all select jsonb_build_object('line_no', 21, 'txn_date', '2026-08-12', 'challan_ref', :'bad_check_ref', 'amount_paisa', 500000, 'bank_ref', 'BKB', 'raw_line', 'badcheck')
  ) x), true);

select public.reconcile_bank_import(:'import_id'::uuid) as recon \gset
reset role;

select is((:'recon'::jsonb ->> 'matched')::int, 8, 'AC: the 8 exact lines are matched and posted (kids 1,3-9)');
select is((:'recon'::jsonb ->> 'exceptions')::int, 5, 'AC: the other 5 lines are queued as exceptions');
select is((select count(*)::int from public.fee_payment where bank_account_id = :'bank_id' and mode = 'bank_challan'), 8, 'eight bank_challan payments exist');
select is((select count(*)::int from public.fee_challan c join recon_kid k on k.challan_id = c.id where c.status = 'paid' and k.n in (1, 3, 4, 5, 6, 7, 8, 9)), 8, 'AC: those 8 challans moved to paid');
select is((select reason from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK2'), 'amount_mismatch', 'AC: 4,000 against 5,000 is an amount_mismatch');
select is((select expected_paisa || '/' || received_paisa from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK2'), '500000/400000', 'with the expected and received amounts recorded');
select is((select reason from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK10'), 'possible_duplicate', 'AC: a challan already paid at the cash counter is possible_duplicate');
select is((select count(*)::int from public.fee_payment where reference_no = 'BK10'), 0, 'and no second payment is posted');
select is((select reason from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK11'), 'cancelled_challan', 'a cancelled challan is queued as cancelled_challan');
select is((select reason from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BKG'), 'unmatched', 'a valid-looking number nobody owns is unmatched');
select is((select reason from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BKB'), 'check_digit_fail', 'a wrong check digit is check_digit_fail');

-- ── rerun safety ──────────────────────────────────────────────────────────

update public.bank_statement_line set status = 'parsed' where import_id = :'import_id'::uuid and bank_ref = 'BK1';
delete from public.bank_recon_exception where line_id in (select id from public.bank_statement_line where bank_ref = 'BK1');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reconcile_bank_import(:'import_id'::uuid) as rerun \gset
reset role;
select is((select count(*)::int from public.fee_payment where reference_no = 'BK1'), 1, 'AC: reprocessing a statement line never creates a second payment');
select throws_ok(
  format($$ insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, reference_no, bank_account_id) values (%L, %L, %L, 1, 'bank_challan', 'BK1', %L) $$,
    :'tenant_id', :'campus_id', (select enrol_id from recon_kid where n = 1), :'bank_id'),
  '23505', null, 'AC: the unique index on (bank_account_id, reference_no) stops it at the table too');

-- ── resolution ────────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.close_bank_import(%L) $$, :'import_id'), 'UNRESOLVED_EXCEPTIONS', 'AC: close is blocked while exceptions are unresolved');
select throws_ok(
  format($$ select public.resolve_bank_exception(%L, 'dismiss', 'x') $$, (select e.id from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BKG')),
  'RESOLUTION_NOTE_REQUIRED', 'a resolution needs a real note');
select public.resolve_bank_exception((select e.id from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK2'), 'post', 'Parent paid the pre-due amount after the due date') as res2 \gset
select throws_ok(
  format($$ select public.resolve_bank_exception(%L, 'post', 'cannot post a cancelled challan') $$, (select e.id from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BK11')),
  'CANCELLED_CHALLAN_CANNOT_BE_POSTED', 'a cancelled challan cannot be confirmed into a payment');
select public.resolve_bank_exception((select e.id from public.bank_recon_exception e join public.bank_statement_line l on l.id = e.line_id where l.bank_ref = 'BKG'), 'post', 'Matched by hand to kid 12', (select challan_id from recon_kid where n = 12)) as res_ghost \gset
reset role;
select is((:'res2'::jsonb ->> 'status'), 'posted', 'AC: the accountant confirms the mismatch into a payment');
select is((select status::text from public.fee_challan where id = (select challan_id from recon_kid where n = 2)), 'part_paid', 'AC: which posts as a partial payment');
select is(app.fn_challan_balance((select challan_id from recon_kid where n = 2)), 100000::bigint, 'AC: leaving 1,000 outstanding');
select is((select status::text from public.fee_challan where id = (select challan_id from recon_kid where n = 12)), 'paid', 'an unmatched line can be posted against a challan the accountant picks');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.resolve_bank_exception(e.id, 'dismiss', 'Reviewed with the bank: not ours') from public.bank_recon_exception e where e.resolved_at is null;
select lives_ok(format($$ select public.close_bank_import(%L) $$, :'import_id'), 'AC: with every exception resolved the import closes');
reset role;
select is((select status from public.bank_statement_import where id = :'import_id'), 'closed', 'the import is closed');
select is((select unresolved_count::int from public.v_bank_recon_summary where import_id = :'import_id'), 0, 'the summary view reports 0 unresolved');

-- ── isolation ─────────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.bank_recon_exception), 0, 'another school sees no exceptions');
select throws_ok(format($$ select public.reconcile_bank_import(%L) $$, :'import_id'), 'IMPORT_NOT_FOUND', 'nor can it reconcile this import');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.reconcile_bank_import(%L) $$, :'import_id'), 'FORBIDDEN', 'a teacher cannot reconcile');
reset role;

select * from finish();
rollback;
