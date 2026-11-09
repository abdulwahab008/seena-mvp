begin;
select plan(16);

select is(app.fn_recurring_next_run('2026-01-31', 'monthly', '2026-01-31'), '2026-02-28'::date, 'a run due on the 31st falls on the last day of February');
select is(app.fn_recurring_next_run('2026-01-31', 'monthly', '2026-02-28'), '2026-03-31'::date, 'and goes back to the 31st after');
select is(app.fn_recurring_next_run('2026-01-15', 'quarterly', '2026-04-15'), '2026-07-15'::date, 'quarterly runs are three months apart');

select public.provision_tenant('test-recurring-a', 'Recurring A', 'owner@recurring-a.test') as tenant_a \gset
select public.provision_tenant('test-recurring-b', 'Recurring B', 'owner@recurring-b.test') as tenant_b \gset
select gen_random_uuid() as uid_a \gset
select gen_random_uuid() as uid_b \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'uid_a', 'acc@recurring-a.test', 'authenticated', 'authenticated', 'x'),
  (:'uid_b', 'acc@recurring-b.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'accountant')::text, true);
select public.ensure_chart_of_accounts();
select id as bank from public.gl_account where code = '1010' \gset
select id as rent from public.gl_account where code = '5200' \gset
select id as repairs from public.gl_account where code = '5400' \gset

select throws_ok(format($$ select public.save_recurring_journal('Rent', 'Rent', 'monthly', current_date, jsonb_build_array(
  jsonb_build_object('account_id', %L, 'debit', 100), jsonb_build_object('account_id', %L, 'credit', 90))) $$, :'rent', :'bank'),
  '22023', 'NOT_BALANCED', 'an unbalanced template is refused');

select public.save_recurring_journal('Building rent', 'Monthly rent', 'monthly', (current_date - interval '2 months')::date, jsonb_build_array(
  jsonb_build_object('account_id', :'rent', 'debit', 15000000), jsonb_build_object('account_id', :'bank', 'credit', 15000000))) as rent_tpl \gset
select public.save_recurring_journal('Generator service', 'Generator service', 'yearly', current_date, jsonb_build_array(
  jsonb_build_object('account_id', :'repairs', 'debit', 500000), jsonb_build_object('account_id', :'bank', 'credit', 500000))) as gen_tpl \gset
select public.set_recurring_journal_active(:'gen_tpl', false);

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'principal')::text, true);
select throws_ok($$ select public.post_due_recurring_journals() $$, '42501', 'FORBIDDEN', 'a principal cannot post recurring vouchers');
select is((select count(*)::int from public.gl_recurring_journal), 2, 'but can see the templates');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_b', 'tenant_id', :'tenant_b', 'app_role', 'accountant')::text, true);
select is(public.post_due_recurring_journals(), 0, 'another school''s button posts nothing of ours');
select throws_ok(format($$ select public.set_recurring_journal_active(%L, true) $$, :'rent_tpl'), 'P0002', 'TEMPLATE_NOT_FOUND', 'nor can it switch our templates on');
select is((select count(*)::int from public.gl_recurring_journal), 0, 'nor see them');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'accountant')::text, true);
select is(public.post_due_recurring_journals(), 3, 'three missed months of rent post at once; the paused template does not');
select is((select balance from public.trial_balance(current_date) where code = '5200'), 45000000::bigint, 'the vouchers reach the ledger');
select ok((select bool_and(entry_no ~ '^JV-') from public.journal_entry e join public.gl_recurring_journal_run r on r.entry_id = e.id), 'each run is a numbered voucher');
select ok((select next_run > current_date from public.gl_recurring_journal where id = :'rent_tpl'), 'the template moves to its next due date');
select is(public.post_due_recurring_journals(), 0, 'pressing the button again posts nothing');

select public.set_recurring_journal_active(:'gen_tpl', true);
select public.save_gl_account('5400', 'Repairs and maintenance', 'expense', false, :'repairs');
select throws_ok($$ select public.post_due_recurring_journals() $$, 'P0002', 'ACCOUNT_NOT_FOUND', 'a template on a closed account is refused by the voucher checks');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.gl_recurring_journal_line), 0, 'teachers cannot see template lines');

select * from finish();
rollback;
