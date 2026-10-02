-- pgTAP tests for FR-R01: item master and immutable stock ledger per campus store.
begin;
select plan(24);

select public.provision_tenant('test-inv-co', 'Inventory Co', 'owner@inv.test');
select id as tenant_id from public.tenant where slug = 'test-inv-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Second Campus', 'C2') returning id as campus2_id \gset
select public.provision_tenant('test-inv-other', 'Other Inv Co', 'owner@otherinv.test');
select id as other_tenant_id from public.tenant where slug = 'test-inv-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as acct2_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@inv.test', 'authenticated', 'authenticated', 'x'), (:'acct2_uid', 'a2@inv.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@inv.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant One'), (:'acct2_uid', :'tenant_id', 'accountant', 'Accountant Two'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.create_inv_item('SHIRT-26', 'School Shirt', 'uniform', 'pcs', '26', null, null, 20, 120000) as shirt \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as store1 \gset

-- ── AC1: 200 received, 143 sold -> 57 on hand, exactly 2 movement rows ─────
select public.post_stock_movement(:'store1'::uuid, :'shirt'::uuid, 'receipt', 200, 90000);
select public.post_stock_movement(:'store1'::uuid, :'shirt'::uuid, 'sale', 143);
select is((select on_hand from public.v_stock_on_hand where store_id = :'store1'::uuid and item_id = :'shirt'::uuid), 57::numeric, 'AC1: 200 received and 143 sold leaves 57 on hand');
select is((select count(*) from public.inv_stock_movement where store_id = :'store1'::uuid and item_id = :'shirt'::uuid), 2::bigint, 'AC1: exactly 2 movement rows explain the balance');
select is((select qty from public.inv_stock_movement where movement_type = 'sale' and item_id = :'shirt'::uuid), -143::numeric, 'a sale is stored as a negative quantity');
select is((select moved_by from public.inv_stock_movement where movement_type = 'receipt' and item_id = :'shirt'::uuid), :'acct_uid'::uuid, 'the mover is recorded');

-- ── AC2: insufficient stock refused, nothing written ──────────────────────
select public.post_stock_variance(:'store1'::uuid, :'shirt'::uuid, 2, 'COUNT_ERROR');
select is((select on_hand from public.v_stock_on_hand where store_id = :'store1'::uuid and item_id = :'shirt'::uuid), 2::numeric, 'on hand is brought to 2 for the next check');
select throws_ok(format($$ select public.post_stock_movement(%L, %L, 'sale', 3) $$, :'store1', :'shirt'), 'INSUFFICIENT_STOCK', 'AC2: selling 3 when 2 are on hand is refused with INSUFFICIENT_STOCK');
select is((select count(*) from public.inv_stock_movement where store_id = :'store1'::uuid and item_id = :'shirt'::uuid), 3::bigint, 'AC2: and no movement row was written for the refused sale');
select public.post_stock_movement(:'store1'::uuid, :'shirt'::uuid, 'receipt', 55);

-- ── AC3: stock take 55 vs system 57 -> -2 adjustment, originals unchanged ─
-- (system now 57 again: 2 + 55)
select is(public.post_stock_variance(:'store1'::uuid, :'shirt'::uuid, 55, 'SHRINKAGE'), -2::numeric, 'AC3: counting 55 against a system 57 returns a -2 variance');
select is((select qty from public.inv_stock_movement where movement_type = 'adjustment' and reason_code = 'SHRINKAGE' and item_id = :'shirt'::uuid), -2::numeric, 'AC3: a -2 adjustment row with reason SHRINKAGE is written');
select is((select on_hand from public.v_stock_on_hand where store_id = :'store1'::uuid and item_id = :'shirt'::uuid), 55::numeric, 'AC3: on hand becomes 55');
select is((select sum(qty) from public.inv_stock_movement where movement_type in ('receipt', 'sale') and item_id = :'shirt'::uuid), 112::numeric, 'AC3: the original receipt and sale rows are unchanged (200 - 143 + 55)');
select throws_ok(format($$ select public.post_stock_variance(%L, %L, 50, 'MADE_UP') $$, :'store1', :'shirt'), 'REASON_CODE_INVALID', 'a stock take needs a valid reason code');
select is(public.post_stock_variance(:'store1'::uuid, :'shirt'::uuid, 55, 'FOUND'), 0::numeric, 'a count that matches the system posts nothing');

-- ── the ledger is immutable ───────────────────────────────────────────────
reset role;
select throws_ok(format($$ update public.inv_stock_movement set qty = 1 where item_id = %L $$, :'shirt'), 'STOCK_MOVEMENT_IMMUTABLE', 'movements cannot be updated, even by a superuser session');
select throws_ok(format($$ delete from public.inv_stock_movement where item_id = %L $$, :'shirt'), 'STOCK_MOVEMENT_IMMUTABLE', 'movements cannot be deleted');
select is((select count(*) from information_schema.columns where table_schema = 'public' and table_name in ('inv_item', 'inv_store', 'inv_stock_lock') and column_name ~ 'balance|on_hand'), 0::bigint, 'there is no mutable running-balance column');

-- ── AC4: the same item at two campuses has independent stock ──────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct2_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus2_id'))::text, true);
select public.create_inv_store(:'campus2_id'::uuid, 'Main Store') as store2 \gset
select public.post_stock_movement(:'store2'::uuid, :'shirt'::uuid, 'receipt', 10);
select is((select on_hand from public.v_stock_on_hand where item_id = :'shirt'::uuid), 10::numeric, 'AC4: campus 2 sees only its own 10 shirts');
select throws_ok(format($$ select public.post_stock_movement(%L, %L, 'sale', 11) $$, :'store2', :'shirt'), 'INSUFFICIENT_STOCK', 'AC4: campus 2 cannot consume campus 1''s stock');
select throws_ok(format($$ select public.post_stock_movement(%L, %L, 'sale', 1) $$, :'store1', :'shirt'), 'FORBIDDEN', 'AC4: nor post against another campus''s store');

-- ── roles and tenant isolation ────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.post_stock_movement(%L, %L, 'receipt', 1) $$, :'store1', :'shirt'), 'FORBIDDEN', 'a teacher cannot post stock');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.inv_stock_movement), 0::bigint, 'another school sees no movements');

-- ── weekly reorder alert ──────────────────────────────────────────────────
reset role;
select public.inv_reorder_alert_run();
select is((select count(*) from public.inv_reorder_alert where tenant_id = :'tenant_id' and resolved_at is null), 1::bigint, 'only campus 2 (10 on hand, level 20) is alerted; campus 1 (55) is not');
update public.inv_item set reorder_level = 100 where id = :'shirt'::uuid;
select public.inv_reorder_alert_run();
select is((select count(*) from public.inv_reorder_alert where tenant_id = :'tenant_id' and resolved_at is null), 2::bigint, 'both stores are at or below a reorder level of 100 and are alerted');
select public.inv_reorder_alert_run();
select is((select count(*) from public.inv_reorder_alert where tenant_id = :'tenant_id' and resolved_at is null), 2::bigint, 'running again does not duplicate open alerts');

select * from finish();
rollback;
