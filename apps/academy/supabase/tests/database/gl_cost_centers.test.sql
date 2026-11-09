begin;
select plan(12);

select public.provision_tenant('test-costcentre-a', 'Cost Centre A', 'owner@costcentre-a.test') as tenant_a \gset
select public.provision_tenant('test-costcentre-b', 'Cost Centre B', 'owner@costcentre-b.test') as tenant_b \gset
select gen_random_uuid() as uid_a \gset
select gen_random_uuid() as uid_b \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'uid_a', 'acc@costcentre-a.test', 'authenticated', 'authenticated', 'x'),
  (:'uid_b', 'acc@costcentre-b.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid_b', 'tenant_id', :'tenant_b', 'app_role', 'accountant')::text, true);
select public.ensure_chart_of_accounts();
select public.save_gl_cost_center('hostel', 'Hostel') as cc_b \gset

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'accountant')::text, true);
select public.ensure_chart_of_accounts();
select id as cash from public.gl_account where code = '1000' \gset
select id as transport from public.gl_account where code = '5500' \gset
select id as fees from public.gl_account where code = '4200' \gset

select public.save_gl_cost_center('bus-1', 'Bus route 1') as cc_a \gset
select is((select code from public.gl_cost_center where id = :'cc_a'), 'BUS-1', 'an accountant adds a cost centre, code in capitals');

select public.post_journal_entry(current_date, 'Diesel', jsonb_build_array(
  jsonb_build_object('account_id', :'transport', 'debit', 400000, 'cost_center_id', :'cc_a'),
  jsonb_build_object('account_id', :'cash', 'credit', 400000))) as jv1 \gset
select public.post_journal_entry(current_date, 'Transport fees', jsonb_build_array(
  jsonb_build_object('account_id', :'cash', 'debit', 900000),
  jsonb_build_object('account_id', :'fees', 'credit', 900000, 'cost_center_id', :'cc_a'))) as jv2 \gset
select public.post_journal_entry(current_date, 'Diesel, office car', jsonb_build_array(
  jsonb_build_object('account_id', :'transport', 'debit', 100000),
  jsonb_build_object('account_id', :'cash', 'credit', 100000)));

select is((select cost_center_id from public.journal_line where entry_id = :'jv1' and debit > 0), :'cc_a'::uuid, 'a voucher line carries its cost centre');
select is((select amount from public.cost_center_report(current_date, current_date) where cost_center_id = :'cc_a' and code = '5500'), 400000::bigint,
  'the report shows the centre''s expense');
select is((select amount from public.cost_center_report(current_date, current_date) where cost_center_id = :'cc_a' and code = '4200'), 900000::bigint,
  'and its income');
select is((select amount from public.cost_center_report(current_date, current_date) where cost_center_id is null and code = '5500'), 100000::bigint,
  'untagged lines report as unallocated');

select public.reverse_journal_entry(:'jv1', 'Wrong bus');
select is((select count(*)::int from public.cost_center_report(current_date, current_date) where cost_center_id = :'cc_a' and code = '5500'), 0,
  'a reversal keeps the cost centre, so it cancels out');

select throws_ok(format($$ select public.post_journal_entry(current_date, 'x', jsonb_build_array(
  jsonb_build_object('account_id', %L, 'debit', 1, 'cost_center_id', %L), jsonb_build_object('account_id', %L, 'credit', 1))) $$, :'transport', :'cc_b', :'cash'),
  'P0002', 'COST_CENTER_NOT_FOUND', 'another school''s cost centre cannot be used');

select public.save_gl_cost_center('BUS-1', 'Bus route 1', false, :'cc_a');
select throws_ok(format($$ select public.post_journal_entry(current_date, 'x', jsonb_build_array(
  jsonb_build_object('account_id', %L, 'debit', 1, 'cost_center_id', %L), jsonb_build_object('account_id', %L, 'credit', 1))) $$, :'transport', :'cc_a', :'cash'),
  'P0002', 'COST_CENTER_NOT_FOUND', 'an inactive cost centre takes no new postings');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_b', 'tenant_id', :'tenant_b', 'app_role', 'accountant')::text, true);
select throws_ok(format($$ select public.save_gl_cost_center('X', 'Taken over', true, %L) $$, :'cc_a'), 'P0002', 'COST_CENTER_NOT_FOUND',
  'another school''s accountant cannot edit it');
select is((select count(*)::int from public.cost_center_report(current_date, current_date)), 0, 'nor see its postings');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'principal')::text, true);
select throws_ok($$ select public.save_gl_cost_center('ADM', 'Admin') $$, '42501', 'FORBIDDEN', 'a principal can read but not add cost centres');

select set_config('request.jwt.claims', json_build_object('sub', :'uid_a', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.gl_cost_center), 0, 'teachers cannot see cost centres');

select * from finish();
rollback;
