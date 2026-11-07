begin;
select plan(7);

select public.provision_tenant('test-inv-profit', 'Inventory Profit Co', 'owner@invprofit.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'acct_uid', 'a@invprofit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_inv_item('SHIRT-26', 'School Shirt', 'uniform', 'pcs', '26', null, null, 5, 150000) as shirt \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as main_store \gset
select public.create_inv_store(:'campus_id'::uuid, 'Shop Counter') as shop \gset
select public.post_stock_movement(:'main_store'::uuid, :'shirt'::uuid, 'receipt', 100, 90000);
select public.post_stock_movement(:'main_store'::uuid, :'shirt'::uuid, 'receipt', 100, 110000);

select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, 5) $$, :'shop', :'shop', :'shirt'), '22023', 'SAME_STORE', 'a store cannot transfer to itself');
select public.transfer_stock(:'main_store', :'shop', :'shirt', 30) as transfer_ref \gset
reset role;
select is((select sum(qty)::int from public.inv_stock_movement where store_id = :'shop'), 30, 'the shop receives the transferred stock');
select is((select sum(qty)::int from public.inv_stock_movement where store_id = :'main_store'), 170, 'and the main store gives it up');
select is((select count(*)::int || ' ' || min(unit_cost) from public.inv_stock_movement where ref_id = :'transfer_ref'), '2 100000', 'both legs carry the average cost and the same reference');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.transfer_stock(%L, %L, %L, 500) $$, :'main_store', :'shop', :'shirt'), 'INSUFFICIENT_STOCK', 'a store cannot give what it does not have');

-- Ten shirts sold at PKR 1,500, two returned.
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-P1', 'Buyer', '2014-01-01', 'male', 'active') returning id as kid \gset
insert into public.inv_sale (tenant_id, campus_id, store_id, serial, financial_year, student_id, student_gr, student_name, settlement, total)
values (:'tenant_id', :'campus_id', :'shop', 'S-1', 2026, :'kid', 'GR-P1', 'Buyer', 'cash', 1500000) returning id as sale_id \gset
insert into public.inv_sale_line (tenant_id, sale_id, item_id, qty, unit_price, amount) values (:'tenant_id', :'sale_id', :'shirt', 10, 150000, 1500000);
insert into public.inv_sale (tenant_id, campus_id, store_id, doc_type, serial, financial_year, student_id, student_gr, student_name, settlement, total, credit_note_of)
values (:'tenant_id', :'campus_id', :'shop', 'credit_note', 'CN-1', 2026, :'kid', 'GR-P1', 'Buyer', 'cash', 300000, :'sale_id') returning id as cn_id \gset
insert into public.inv_sale_line (tenant_id, sale_id, item_id, qty, unit_price, amount) values (:'tenant_id', :'cn_id', :'shirt', 2, 150000, 300000);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select qty_sold || ' ' || revenue_paisa || ' ' || cost_paisa || ' ' || profit_paisa from public.inventory_profit(current_date - 1, current_date + 1) where item_id = :'shirt'),
  '8 1200000 800000 400000', 'profit is revenue less average cost, net of returns');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select * from public.inventory_profit(current_date, current_date) $$, '42501', 'FORBIDDEN', 'teachers cannot see shop profit');

select * from finish();
rollback;
