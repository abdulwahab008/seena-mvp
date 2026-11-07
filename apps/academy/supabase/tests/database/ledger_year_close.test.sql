begin;
select plan(14);

select public.provision_tenant('test-yearclose-co', 'Year Close Co', 'owner@yearclose.test') as tenant_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'acc@yearclose.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant')::text, true);
select public.ensure_chart_of_accounts();
select id as cash from public.gl_account where code = '1000' \gset
select id as payable from public.gl_account where code = '2000' \gset
select id as tuition from public.gl_account where code = '4000' \gset
select id as utilities from public.gl_account where code = '5100' \gset

-- Opening balances: PKR 500 cash and PKR 200 owed; the PKR 300 difference is the owner's capital.
select public.post_opening_balances('2024-07-01', jsonb_build_array(
  jsonb_build_object('account_id', :'cash', 'amount', 50000), jsonb_build_object('account_id', :'payable', 'amount', 20000)));
select is((select balance from public.trial_balance('2024-07-01') where code = '3000'), 30000::bigint, 'the opening difference is the owner''s capital');
select throws_ok($$ select public.post_opening_balances('2024-07-01', '[]'::jsonb) $$, '22023', 'OPENING_ALREADY_POSTED', 'opening balances post only once');
select throws_ok(format($$ select public.post_opening_balances('2024-07-01', jsonb_build_array(jsonb_build_object('account_id', %L, 'amount', 1))) $$, :'tuition'),
  '22023', 'OPENING_ALREADY_POSTED', 'and never to an income account either');

-- A year of trading: PKR 1,000 fees in, PKR 300 electricity out.
select public.post_journal_entry('2025-03-10', 'Fees', jsonb_build_array(
  jsonb_build_object('account_id', :'cash', 'debit', 100000), jsonb_build_object('account_id', :'tuition', 'credit', 100000)));
select public.post_journal_entry('2025-04-10', 'Electricity', jsonb_build_array(
  jsonb_build_object('account_id', :'utilities', 'debit', 30000), jsonb_build_object('account_id', :'cash', 'credit', 30000)));

select throws_ok($$ select public.close_financial_year(current_date) $$, '22023', 'DATE_INVALID', 'a year closes only after it ends');
select isnt(public.close_financial_year('2025-06-30'), null, 'closing the year posts a closing voucher');
select is((select balance from public.trial_balance('2025-06-30') where code = '3100'), 70000::bigint, 'the year''s surplus moves to retained earnings');
select is((select count(*)::int from public.trial_balance('2025-06-30') where type in ('income', 'expense') and balance <> 0), 0,
  'income and expense accounts start the new year at zero');
select is((select sum(case when type = 'income' then amount else -amount end) from public.income_statement('2024-07-01', '2025-06-30'))::bigint,
  70000::bigint, 'the closed year''s income statement still shows what was earned and spent');
select is((select sum(case when type = 'asset' then amount else -amount end) from public.balance_sheet('2025-06-30'))::bigint, 0::bigint,
  'the balance sheet balances after the close');

select throws_ok(format($$ select public.post_journal_entry('2025-06-20', 'Late bill', jsonb_build_array(
  jsonb_build_object('account_id', %L, 'debit', 100), jsonb_build_object('account_id', %L, 'credit', 100))) $$, :'utilities', :'cash'),
  '22023', 'PERIOD_LOCKED', 'a manual voucher cannot be dated in a closed year');
select throws_ok($$ select public.close_financial_year('2025-06-30') $$, '22023', 'PERIOD_LOCKED', 'a year closes only once');

reset role;
select app.fn_gl_post_system(:'tenant_id', '2025-05-01', 'Backdated fee', 'fee_payment', gen_random_uuid(),
  jsonb_build_array(jsonb_build_object('code', '1000', 'debit', 500), jsonb_build_object('code', '4000', 'credit', 500))) as late_id \gset
select is((select entry_date from public.journal_entry where id = :'late_id'), '2025-07-01'::date,
  'an automatic posting for a closed date lands on the first open day instead of failing');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);
select throws_ok($$ select public.close_financial_year('2025-12-31') $$, '42501', 'FORBIDDEN', 'a principal cannot close the year');
select is((select locked_through from public.gl_setting), '2025-06-30'::date, 'but can see how far the books are closed');

select * from finish();
rollback;
