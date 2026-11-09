begin;
select plan(11);

select public.provision_tenant('test-budget-a', 'Budget A', 'owner@budget-a.test') as tenant_a \gset
select public.provision_tenant('test-budget-b', 'Budget B', 'owner@budget-b.test') as tenant_b \gset
select gen_random_uuid() as uid_a \gset
select gen_random_uuid() as uid_b \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'uid_a', 'acc@budget-a.test', 'authenticated', 'authenticated', 'x'),
  (:'uid_b', 'acc@budget-b.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'accountant')::text, true);
select public.ensure_chart_of_accounts();
select id as cash from public.gl_account where code = '1000' \gset
select id as utilities from public.gl_account where code = '5100' \gset
select id as tuition from public.gl_account where code = '4000' \gset

select throws_ok(format($$ select public.save_account_budget(%L, 2024, array_fill(100::bigint, array[12])) $$, :'cash'),
  'P0002', 'ACCOUNT_NOT_FOUND', 'budgets are for income and expense accounts only');
select throws_ok(format($$ select public.save_account_budget(%L, 2024, array[1, 2, 3]::bigint[]) $$, :'utilities'),
  '22023', 'AMOUNTS_INVALID', 'a budget needs twelve months');

select public.save_account_budget(:'utilities', 2024, array_fill(2000000::bigint, array[12]));
select public.save_account_budget(:'tuition', 2024, array[50000000, 50000000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]::bigint[]);
select is((select count(*)::int from public.gl_budget where account_id = :'utilities'), 12, 'a budget is stored per month');
select is((select min(month) from public.gl_budget), '2024-07-01'::date, 'the year starts in July');

select public.save_account_budget(:'utilities', 2024, array[2500000, 0, 2000000, 2000000, 2000000, 2000000, 2000000, 2000000, 2000000, 2000000, 2000000, 2000000]::bigint[]);
select is((select count(*)::int from public.gl_budget where account_id = :'utilities'), 11, 'saving a zero clears that month');

select public.post_journal_entry('2024-07-20', 'Electricity', jsonb_build_array(
  jsonb_build_object('account_id', :'utilities', 'debit', 3000000), jsonb_build_object('account_id', :'cash', 'credit', 3000000)));
select public.post_journal_entry('2024-08-05', 'Fees', jsonb_build_array(
  jsonb_build_object('account_id', :'cash', 'debit', 45000000), jsonb_build_object('account_id', :'tuition', 'credit', 45000000)));

select results_eq(
  $$ select budget, actual from public.budget_vs_actual(2024) where code = '5100' and month = '2024-07-01' $$,
  $$ values (2500000::bigint, 3000000::bigint) $$,
  'July electricity: budget against what was spent');
select results_eq(
  $$ select budget, actual from public.budget_vs_actual(2024) where code = '4000' and month = '2024-08-01' $$,
  $$ values (50000000::bigint, 45000000::bigint) $$,
  'income is measured on its credit side');
select is((select count(*)::int from public.budget_vs_actual(2025)), 0, 'another year has nothing');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'principal')::text, true);
select throws_ok(format($$ select public.save_account_budget(%L, 2024, array_fill(1::bigint, array[12])) $$, :'utilities'),
  '42501', 'FORBIDDEN', 'a principal can read but not set budgets');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_b', 'tenant_id', :'tenant_b', 'app_role', 'accountant')::text, true);
select throws_ok(format($$ select public.save_account_budget(%L, 2024, array_fill(1::bigint, array[12])) $$, :'utilities'),
  'P0002', 'ACCOUNT_NOT_FOUND', 'another school cannot budget our accounts');
select is((select count(*)::int from public.budget_vs_actual(2024)), 0, 'nor see our budget against actuals');

select * from finish();
rollback;
