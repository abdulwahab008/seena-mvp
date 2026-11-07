begin;
select plan(12);

select public.provision_tenant('test-ledger-co', 'Ledger Co', 'owner@ledger.test') as tenant_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'acc@ledger.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select ok(public.ensure_chart_of_accounts() > 20, 'a standard chart of accounts is created on first use');
select is(public.ensure_chart_of_accounts(), 0, 'and only once');
select id as cash from public.gl_account where code = '1000' \gset
select id as rent from public.gl_account where code = '5200' \gset
select id as capital from public.gl_account where code = '3000' \gset

select throws_ok(format($$ select public.post_journal_entry(current_date, 'Bad', jsonb_build_array(
  jsonb_build_object('account_id', %L, 'debit', 100), jsonb_build_object('account_id', %L, 'credit', 90))) $$, :'rent', :'cash'),
  '22023', 'NOT_BALANCED', 'an unbalanced voucher is refused');
select public.post_journal_entry(current_date, 'Owner puts in capital', jsonb_build_array(
  jsonb_build_object('account_id', :'cash', 'debit', 50000000), jsonb_build_object('account_id', :'capital', 'credit', 50000000))) as jv1 \gset
select public.post_journal_entry(current_date, 'October rent', jsonb_build_array(
  jsonb_build_object('account_id', :'rent', 'debit', 15000000), jsonb_build_object('account_id', :'cash', 'credit', 15000000))) as jv2 \gset
select matches((select entry_no from public.journal_entry where id = :'jv1'), '^JV-[0-9]{4}-00001$', 'vouchers are numbered in sequence');

select is((select balance from public.trial_balance(current_date) where code = '1000'), 35000000::bigint, 'cash balance is capital less rent');
select is((select sum(debit) - sum(credit) from public.trial_balance(current_date))::bigint, 0::bigint, 'the trial balance balances');

reset role;
select throws_ok(format($$ update public.journal_line set debit = 1 where entry_id = %L $$, :'jv2'), '42501', 'JOURNAL_IMMUTABLE', 'a posted line cannot be edited');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);

select public.reverse_journal_entry(:'jv2', 'Rent was for November') as rev \gset
select is((select balance from public.trial_balance(current_date) where code = '5200'), 0::bigint, 'reversing a voucher cancels it out');
select throws_ok(format($$ select public.reverse_journal_entry(%L, 'again') $$, :'jv2'), '22023', 'CANNOT_REVERSE', 'a voucher is reversed only once');
select throws_ok(format($$ select public.save_gl_account('5200', 'Rent', 'asset', true, %L) $$, :'rent'), '22023', 'ACCOUNT_TYPE_LOCKED', 'an account with postings keeps its type');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select throws_ok(format($$ select public.post_journal_entry(current_date, 'x', '[]'::jsonb) $$), '42501', 'FORBIDDEN', 'a principal can read but not post');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.journal_entry), 0, 'teachers cannot see the ledger');

select * from finish();
rollback;
