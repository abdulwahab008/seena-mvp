begin;
select plan(21);

select public.provision_tenant('test-autopost-co', 'Autopost Co', 'owner@autopost.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'acc@autopost.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'accountant', 'Auto Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Early Payer', '2015-01-01'::date, 'male') as early_student \gset
select public.enrol_student(:'section_id'::uuid, :'early_student'::uuid) as early_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Later Payer', '2015-01-01'::date, 'female') as later_student \gset
select public.enrol_student(:'section_id'::uuid, :'later_student'::uuid) as later_enrol \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- Before the school opens Accounts nothing posts.
select public.record_payment(:'early_enrol'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode, 'early');
set constraints all immediate;
set constraints all deferred;
select is((select count(*)::int from public.journal_entry), 0, 'nothing posts before the chart of accounts exists');

select public.ensure_chart_of_accounts();
select is(public.post_ledger_backfill(), 1, 'the backfill posts the earlier fee payment');
select is(public.post_ledger_backfill(), 0, 'running the backfill again posts nothing twice');

-- A fee paid by bank posts Dr Bank, Cr the fee head's income account.
select throws_ok(format($$ select public.set_head_gl_code('fee', %L, '5000') $$, :'tuition_id'), 'P0002', 'ACCOUNT_NOT_FOUND', 'a fee head cannot post to an expense account');
select public.set_head_gl_code('fee', :'tuition_id'::uuid, '4100');
select public.record_payment(:'later_enrol'::uuid, 500000::bigint, 'bank_challan'::public.fee_payment_mode, 'BK-1') as later_pay \gset
set constraints all immediate;
set constraints all deferred;
select id as later_entry from public.journal_entry where source_kind = 'fee_payment' and source_id = :'later_pay' \gset
select is((select debit from public.journal_line l join public.gl_account a on a.id = l.account_id where l.entry_id = :'later_entry' and a.code = '1010'),
  500000::bigint, 'a bank payment debits Bank');
select is((select sum(credit)::bigint from public.journal_line l join public.gl_account a on a.id = l.account_id where l.entry_id = :'later_entry' and a.type = 'income'),
  500000::bigint, 'and credits fee income');
select is((select credit from public.journal_line l join public.gl_account a on a.id = l.account_id where l.entry_id = :'later_entry' and a.code = '4100'),
  500000::bigint, 'on the account chosen for the fee head');

reset role;
-- Money not allocated to any challan is a liability, not income; adjustments move no money.
insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, reference_no)
values (:'tenant_id', :'campus_id', :'later_enrol', 30000, 'online', 'ADV-1') returning id as adv_pay \gset
insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, reference_no)
values (:'tenant_id', :'campus_id', :'later_enrol', 1000, 'adjustment', 'ADJ-1') returning id as adj_pay \gset
set constraints all immediate;
set constraints all deferred;
select is((select l.credit from public.journal_entry e join public.journal_line l on l.entry_id = e.id join public.gl_account a on a.id = l.account_id
            where e.source_id = :'adv_pay' and a.code = '2200'), 30000::bigint, 'an unallocated payment is held as fees received in advance');
select is((select count(*)::int from public.journal_entry where source_id = :'adj_pay'), 0, 'an adjustment payment posts nothing');

-- An expense posts to its head's mapped account and to Cash when paid without a bank reference.
insert into public.expense_head (tenant_id, code, name_en, name_ur, gl_code) values (:'tenant_id', 'ELEC', 'Electricity', 'بجلی', '5100') returning id as elec_head \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.submit_expense_voucher(:'campus_id'::uuid, :'elec_head'::uuid, 'LESCO', 120000::bigint, current_date) ->> 'voucher_id' as exp_id \gset
select is((select count(*)::int from public.journal_entry where source_id = :'exp_id'), 0, 'an approved but unpaid expense posts nothing');
select public.mark_expense_voucher_paid(:'exp_id'::uuid);
reset role;
select is((select string_agg(a.code || case when l.debit > 0 then 'Dr' else 'Cr' end, ',' order by a.code) from public.journal_entry e
             join public.journal_line l on l.entry_id = e.id join public.gl_account a on a.id = l.account_id where e.source_id = :'exp_id'),
  '1000Cr,5100Dr', 'a paid expense debits its mapped account and credits Cash');

-- Payroll: accrued when locked, cleared from the bank when paid.
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
values (:'tenant_id', :'campus_id', 'E-1', '35201-1234567-1', 'female', 'Teacher One') returning id as staff_id \gset
insert into public.payroll_run (tenant_id, campus_id, period_month) values (:'tenant_id', :'campus_id', date_trunc('month', current_date)::date) returning id as run_id \gset
insert into public.payroll_run_line (payroll_run_id, staff_id, basic_paisa, gross_paisa, attendance_deduction_paisa, tax_withholding_paisa, loan_recovery_paisa, net_paisa)
values (:'run_id', :'staff_id', 6000000, 6000000, 200000, 300000, 500000, 5000000);
update public.payroll_run set status = 'locked', locked_at = now() where id = :'run_id';
select is((select l.debit from public.journal_entry e join public.journal_line l on l.entry_id = e.id join public.gl_account a on a.id = l.account_id
            where e.source_kind = 'payroll_accrual' and e.source_id = :'run_id' and a.code = '5000'),
  5800000::bigint, 'a locked payroll accrues salaries earned (gross less attendance deductions)');
select is((select l.credit from public.journal_entry e join public.journal_line l on l.entry_id = e.id join public.gl_account a on a.id = l.account_id
            where e.source_kind = 'payroll_accrual' and e.source_id = :'run_id' and a.code = '2100'),
  5000000::bigint, 'with net pay owed to staff');
update public.payroll_run set status = 'paid' where id = :'run_id';
select is((select count(*)::int from public.journal_entry where source_kind = 'payroll_payment' and source_id = :'run_id'), 1, 'paying the run posts the bank payment');

-- Shop: a cash sale is income; its credit note reverses it.
insert into public.inv_store (tenant_id, campus_id, name) values (:'tenant_id', :'campus_id', 'Shop') returning id as store_id \gset
insert into public.inv_sale (tenant_id, campus_id, store_id, serial, financial_year, student_id, student_gr, student_name, settlement, total)
values (:'tenant_id', :'campus_id', :'store_id', 'S-1', 2026, :'later_student', 'GR1', 'Later Payer', 'cash', 80000) returning id as sale_id \gset
insert into public.inv_sale (tenant_id, campus_id, store_id, doc_type, serial, financial_year, student_id, student_gr, student_name, settlement, total, credit_note_of)
values (:'tenant_id', :'campus_id', :'store_id', 'credit_note', 'CN-1', 2026, :'later_student', 'GR1', 'Later Payer', 'cash', 20000, :'sale_id') returning id as cn_id \gset
insert into public.inv_sale (tenant_id, campus_id, store_id, serial, financial_year, student_id, student_gr, student_name, settlement, total)
values (:'tenant_id', :'campus_id', :'store_id', 'S-2', 2026, :'later_student', 'GR1', 'Later Payer', 'fee_ledger', 99000) returning id as ledger_sale \gset
select is((select balance from public.trial_balance(current_date) where code = '4300' and account_id in (select id from public.gl_account where tenant_id = :'tenant_id')), 60000::bigint, 'cash sales less refunds are shop income');
select is((select count(*)::int from public.journal_entry where source_id = :'ledger_sale'), 0, 'a sale charged to fees waits for the fee payment');

-- Statements, as the school's accountant: RLS is what scopes them to one school.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select sum(debit) - sum(credit) from public.trial_balance(current_date))::bigint, 0::bigint, 'the trial balance still balances');
select is((select sum(case when type = 'income' then amount else -amount end) from public.income_statement(current_date - 1, current_date))::bigint,
  (500000 + 500000 + 60000 - 120000 - 5800000)::bigint, 'the income statement nets income against expenses');
select is((select sum(case when type = 'asset' then amount else -amount end) from public.balance_sheet(current_date))::bigint, 0::bigint,
  'assets equal liabilities plus equity');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select throws_ok('select public.post_ledger_backfill()', '42501', 'FORBIDDEN', 'only the accountant or owner can run the backfill');
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.balance_sheet(current_date)), 0, 'teachers cannot read the statements');

select * from finish();
rollback;
