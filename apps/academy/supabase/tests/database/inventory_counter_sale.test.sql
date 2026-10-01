-- pgTAP tests for FR-R02: counter sale of stock to students.
begin;
select plan(33);

select app.fn_financial_year(app.fn_karachi_today()) as fy \gset
select public.provision_tenant('test-sale-co', 'Sale Co', 'owner@sale.test');
select id as tenant_id from public.tenant where slug = 'test-sale-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-sale-other', 'Other Sale Co', 'owner@othersale.test');
select id as other_tenant_id from public.tenant where slug = 'test-sale-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as stranger_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@sale.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@sale.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'p@sale.test', 'authenticated', 'authenticated', 'x'), (:'stranger_uid', 's@sale.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'),
  (:'parent_uid', :'tenant_id', 'parent', 'Parent'), (:'stranger_uid', :'tenant_id', 'parent', 'Stranger');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Ayesha Khan', '2015-01-01'::date, 'female') as stu \gset
select public.create_student(:'campus_id'::uuid, 'Bilal Khan', '2015-02-01'::date, 'male') as stu2 \gset
select public.enrol_student(:'sec'::uuid, :'stu'::uuid) as enr \gset
select public.enrol_student(:'sec'::uuid, :'stu2'::uuid) as enr2 \gset
select public.create_inv_item('SHIRT-26', 'School Shirt', 'uniform', 'pcs', '26', null, null, 0, 120000) as shirt \gset
select public.create_inv_item('BOOK-ENG1', 'English Book 1', 'textbook', 'pcs', null, null, null, 0, 65000) as book \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as store \gset
select public.post_stock_movement(:'store'::uuid, :'shirt'::uuid, 'receipt', 10);
select public.post_stock_movement(:'store'::uuid, :'book'::uuid, 'receipt', 10);

reset role;
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Khan Senior', :'parent_uid') returning id as g1 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values (:'tenant_id', :'stu', :'g1', 'father', true, true);
-- the counter is at 217 so the next receipt is 00218
insert into public.inv_receipt_counter (tenant_id, campus_id, financial_year, last_serial)
values (:'tenant_id', :'campus_id', :'fy', 217);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: 2 shirts at 1,200 and 1 book at 650 -> PKR 3,050, serial UNI-<fy>-00218 ──
select public.create_sale(:'stu'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 2), jsonb_build_object('item_id', :'book', 'qty', 1)), 'cash') as r1 \gset
select is((:'r1'::jsonb ->> 'total_paisa')::bigint, 305000::bigint, 'AC1: the receipt totals PKR 3,050');
select is(:'r1'::jsonb ->> 'serial', 'UNI-' || :'fy' || '-00218', 'AC1: serial is UNI-<year>-00218');
select is(:'r1'::jsonb -> 'student' ->> 'gr_number', (select gr_number from public.student where id = :'stu'::uuid), 'AC1: the receipt prints the GR number');
select is(:'r1'::jsonb -> 'student' ->> 'name', 'Ayesha Khan', 'AC1: and the student name');
select ok((:'r1'::jsonb -> 'student' ->> 'class') like '%A', 'AC1: and the class');
select is((select on_hand from public.v_stock_on_hand where item_id = :'shirt'::uuid), 8::numeric, 'the sale took 2 shirts out of stock');

-- ── cash settlement: cash book yes, ledger no ─────────────────────────────
select is((select sum(amount_paisa) from public.v_inv_cash_book_entry where sale_id = (:'r1'::jsonb ->> 'sale_id')::uuid), 305000::numeric, 'a cash sale is on the cash book');
select is((select count(*) from public.fee_ledger where source_type = 'inv_sale' and enrolment_id = :'enr'::uuid), 0::bigint, 'and posts nothing to the fee ledger');

-- ── AC2: charge-to-fee: UNIFORM_BOOKS on the next challan, no cash book entry ──
select public.create_sale(:'stu'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 1)), 'fee_ledger') as r2 \gset
select is(:'r2'::jsonb ->> 'serial', 'UNI-' || :'fy' || '-00219', 'the next receipt is 00219');
select is((select count(*) from public.v_inv_cash_book_entry where sale_id = (:'r2'::jsonb ->> 'sale_id')::uuid), 0::bigint, 'AC2: a charge-to-fee sale creates no cash book entry');
select is((select amount_paisa from public.fee_ledger where source_type = 'inv_sale' and source_id = (:'r2'::jsonb ->> 'sale_id')::uuid), 120000::bigint, 'AC2: the amount is a debit on the student''s fee ledger');
select is((select h.code from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.source_id = (:'r2'::jsonb ->> 'sale_id')::uuid), 'UNIFORM_BOOKS', 'AC2: under the UNIFORM_BOOKS head');
reset role;
insert into public.fee_challan (tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, due_date, gross_paisa, net_paisa)
values (:'tenant_id', :'campus_id', :'enr', :'session_id', date_trunc('month', current_date)::date, 'CH-SALE-1', current_date + 10, 850000, 850000) returning id as ch1 \gset
select is((select net_paisa from public.fee_challan_line l join public.fee_head h on h.id = l.fee_head_id where l.challan_id = :'ch1' and h.code = 'UNIFORM_BOOKS'), 120000::bigint, 'AC2: a UNIFORM_BOOKS line appears on the student''s next challan');
select is((select net_paisa from public.fee_challan where id = :'ch1'), 970000::bigint, 'and the challan total includes it');
insert into public.fee_challan (tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, due_date, gross_paisa, net_paisa)
values (:'tenant_id', :'campus_id', :'enr', :'session_id', (date_trunc('month', current_date) + interval '1 month')::date, 'CH-SALE-2', current_date + 40, 850000, 850000) returning id as ch2 \gset
select is((select count(*) from public.fee_challan_line where challan_id = :'ch2'), 0::bigint, 'the sale is billed once: the challan after that has no UNIFORM_BOOKS line');

-- ── AC3: return inside the window -> credit note, +1 stock, receipt untouched ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.return_sale_items((:'r1'::jsonb ->> 'sale_id')::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 1))) as cn \gset
select is(:'cn'::jsonb ->> 'doc_type', 'credit_note', 'AC3: a credit note is issued');
select is((:'cn'::jsonb ->> 'total_paisa')::bigint, 120000::bigint, 'for the price paid');
select is((select on_hand from public.v_stock_on_hand where item_id = :'shirt'::uuid), 8::numeric, 'AC3: a +1 return movement puts the shirt back (7 + 1)');
select is((select qty from public.inv_stock_movement where movement_type = 'return' and item_id = :'shirt'::uuid), 1::numeric, 'AC3: the movement is +1');
select is((select total from public.inv_sale where id = (:'r1'::jsonb ->> 'sale_id')::uuid), 305000::bigint, 'AC3: the original receipt row is unchanged');
select throws_ok(format($$ select public.return_sale_items(%L, %L::jsonb) $$, :'r1'::jsonb ->> 'sale_id', jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 2))), 'RETURN_EXCEEDS_SOLD', 'cannot return more than was sold (2 sold, 1 already back)');
reset role;
select throws_ok(format($$ update public.inv_sale set total = 1 where id = %L $$, :'r1'::jsonb ->> 'sale_id'), 'SALE_RECEIPT_IMMUTABLE', 'a receipt can never be edited, by anyone');
alter table public.inv_sale disable trigger trg_inv_sale_immutable;
update public.inv_sale set sold_at = sold_at - interval '9 days' where id = (:'r1'::jsonb ->> 'sale_id')::uuid;
alter table public.inv_sale enable trigger trg_inv_sale_immutable;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.return_sale_items(%L, %L::jsonb) $$, :'r1'::jsonb ->> 'sale_id', jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 1))), 'RETURN_WINDOW_EXPIRED', 'AC3: after the 7-day window a return is refused');

-- ── AC4: serials are unique and gapless, even across a failed sale ──────────
select throws_ok(format($$ select public.create_sale(%L, %L::jsonb, 'cash') $$, :'stu2', jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 99))), 'INSUFFICIENT_STOCK', 'a sale that cannot be filled is refused');
select public.create_sale(:'stu2'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 1)), 'cash') as r4 \gset
select is(:'r4'::jsonb ->> 'serial', 'UNI-' || :'fy' || '-00221', 'AC4: after sale 218, 219 and credit note 220, the refused sale burned no number (221)');
reset role;
select is((select last_serial from public.inv_receipt_counter where tenant_id = :'tenant_id'), 221::bigint, 'AC4: the locked counter row holds the last serial');
select is((select count(*) from pg_indexes where indexname = 'uq_sale_serial'), 1::bigint, 'AC4: uq_sale_serial makes duplicates impossible');

-- ── books already in the admission package are not sold again ───────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.grant_student_entitlement(:'stu2'::uuid, :'book'::uuid, 1);
select throws_ok(format($$ select public.create_sale(%L, %L::jsonb, 'fee_ledger') $$, :'stu2', jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 1))), 'ALREADY_COVERED_BY_PACKAGE', 'a book the admission package covers cannot be sold again');
select is((public.get_sale_context(:'stu2'::uuid) -> 'package' -> 0 ->> 'remaining')::numeric, 1::numeric, 'the sale screen is shown what the package still covers');
select is((public.create_sale(:'stu2'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 1, 'from_package', true)), 'fee_ledger') ->> 'total_paisa')::bigint, 0::bigint, 'issuing it from the package costs nothing and charges nothing');
select throws_ok(format($$ select public.create_sale(%L, %L::jsonb, 'cash') $$, :'stu2', jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 1, 'from_package', true))), 'PACKAGE_ENTITLEMENT_EXCEEDED', 'and the entitlement cannot be drawn twice');

-- ── a parent reads only their own child's purchases ───────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.inv_sale where student_id = :'stu'::uuid), 3::bigint, 'a parent sees their child''s receipts and credit note');
select is((select count(*) from public.inv_sale where student_id = :'stu2'::uuid), 0::bigint, 'but not another child''s');

select * from finish();
rollback;
