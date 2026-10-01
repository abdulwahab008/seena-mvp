-- pgTAP tests: counter sales of stock (FR-R02) and library fines settled at the counter (FR-O07) feed the
-- cash-counter day close and the daily collection report exactly once; finalised days stay immutable.
begin;
select plan(23);

select app.fn_karachi_today() as today \gset
select (app.fn_karachi_today() + 1) as tomorrow \gset

select public.provision_tenant('test-ccb-co', 'Cash Book Co', 'owner@ccb.test');
select id as tenant_id from public.tenant where slug = 'test-ccb-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@ccb.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@ccb.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'acct_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Ayesha Khan', '2015-01-01'::date, 'female') as stu \gset
select public.enrol_student(:'sec'::uuid, :'stu'::uuid) as enr \gset
select public.create_inv_item('SHIRT-26', 'School Shirt', 'uniform', 'pcs', '26', null, null, 0, 120000) as shirt \gset
select public.create_inv_item('BOOK-ENG1', 'English Book 1', 'textbook', 'pcs', null, null, null, 0, 65000) as book \gset
select public.create_inv_store(:'campus_id'::uuid, 'Main Store') as store \gset
select public.post_stock_movement(:'store'::uuid, :'shirt'::uuid, 'receipt', 20);
select public.post_stock_movement(:'store'::uuid, :'book'::uuid, 'receipt', 20);

-- library fines: three nightly rows on one loan, one outstanding row on another
reset role;
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics X') returning id as tx \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode, status)
select :'tenant_id', :'campus_id', :'tx', 'ACC-' || n, 'BC' || n, 'issued' from generate_series(1, 2) n;
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, issued_at, due_on, policy_snapshot)
select :'tenant_id', :'campus_id', c.id, :'stu'::uuid, 'student', now() - interval '20 days', :'today'::date - 5, '{}'::jsonb
  from public.library_copy c where c.tenant_id = :'tenant_id' and c.barcode in ('BC1', 'BC2');
select l.id as loan1 from public.library_loan l join public.library_copy c on c.id = l.copy_id where c.tenant_id = :'tenant_id' and c.barcode = 'BC1' \gset
select l.id as loan2 from public.library_loan l join public.library_copy c on c.id = l.copy_id where c.tenant_id = :'tenant_id' and c.barcode = 'BC2' \gset
insert into public.library_fine (tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount)
select :'tenant_id', :'campus_id', :'loan1'::uuid, :'stu'::uuid, :'today'::date - 3 + n, n, 1000 from generate_series(1, 3) n;
insert into public.library_fine (tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount)
values (:'tenant_id', :'campus_id', :'loan2'::uuid, :'stu'::uuid, :'today'::date, 5, 2500);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── counter sales ───────────────────────────────────────────────────────────
select public.create_sale(:'stu'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 2), jsonb_build_object('item_id', :'book', 'qty', 1)), 'cash') as r1 \gset
select public.create_sale(:'stu'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 1)), 'fee_ledger') as r2 \gset
select is((select book_date from public.inv_sale where id = (:'r1'::jsonb ->> 'sale_id')::uuid), :'today'::date, 'a cash sale is stamped with today''s book date');
select is((select book_date from public.inv_sale where id = (:'r2'::jsonb ->> 'sale_id')::uuid), null::date, 'a charge-to-fee sale has no cash book date');
select is((select coalesce(sum(amount_paisa), 0)::bigint from public.v_daily_collection where campus_id = :'campus_id'::uuid and value_date = :'today'::date), 305000::bigint, 'only the cash sale is in the day''s collection, the charge-to-fee sale is not');

-- ── library fines settled at the counter ────────────────────────────────────
select is(public.settle_library_fines(:'stu'::uuid, :'loan1'::uuid), 3000::bigint, 'the Accountant settles the three nightly rows of one loan');
select is((select count(*) from public.v_library_fine_cash_entry where campus_id = :'campus_id'::uuid and book_date = :'today'::date), 1::bigint, 'they are one cash receipt, not three');
select public.waive_library_fines(:'stu'::uuid, 'Hardship, approved by principal', :'loan2'::uuid);
select is((select coalesce(sum(amount_paisa), 0)::bigint from public.v_library_fine_cash_entry where campus_id = :'campus_id'::uuid), 3000::bigint, 'a waived fine is not cash');

-- ── cash refund of returned stock ───────────────────────────────────────────
select public.return_sale_items((:'r1'::jsonb ->> 'sale_id')::uuid, jsonb_build_array(jsonb_build_object('item_id', :'shirt', 'qty', 1))) as cn \gset
select is((select book_date from public.inv_sale where id = (:'cn'::jsonb ->> 'sale_id')::uuid), :'today'::date, 'the cash credit note is stamped with today');

-- ── the collection report ties to the ledger of receipts ───────────────────
select is((select amount_paisa from public.daily_collection_report(:'campus_id'::uuid, :'today'::date, :'today'::date) where mode = 'cash'), 308000::bigint, 'report: cash = sale PKR 3,050 + library fines PKR 30');
select is((select payment_count from public.daily_collection_report(:'campus_id'::uuid, :'today'::date, :'today'::date) where mode = 'cash'), 2::bigint, 'report: two receipts');
select is((public.build_collection_report_payload(:'today'::date, :'today'::date, :'campus_id'::uuid) ->> 'grand_total_paisa')::bigint, 308000::bigint, 'report payload grand total agrees');
select is((select sum(amount_paisa)::bigint from public.daily_collection_report(:'campus_id'::uuid, :'today'::date, :'today'::date)), 308000::bigint, 'mode subtotals sum to the grand total');

-- ── the day close ───────────────────────────────────────────────────────────
select public.finalise_cash_book_day(:'campus_id'::uuid, :'today'::date) as day1 \gset
select is((select receipts_paisa from public.cash_book_day where campus_id = :'campus_id'::uuid and book_date = :'today'::date), 308000::bigint, 'day close: receipts include the counter sale and the fines exactly once');
select is((select disbursements_paisa from public.cash_book_day where campus_id = :'campus_id'::uuid and book_date = :'today'::date), 120000::bigint, 'day close: the cash refund of one shirt is a disbursement');
select is((select closing_paisa from public.cash_book_day where campus_id = :'campus_id'::uuid and book_date = :'today'::date), 188000::bigint, 'day close: closing = opening + receipts - disbursements');
select throws_ok(format($$ select public.finalise_cash_book_day(%L, %L) $$, :'campus_id', :'today'), 'ALREADY_FINALISED', 'a finalised day cannot be finalised again');

-- ── finalised days stay immutable ───────────────────────────────────────────
reset role;
select throws_ok(format($$ update public.cash_book_day set receipts_paisa = 0 where campus_id = %L $$, :'campus_id'), 'CASH_BOOK_DAY_IMMUTABLE', 'a finalised day row cannot be updated');
select throws_ok(format($$ delete from public.cash_book_day where campus_id = %L $$, :'campus_id'), 'CASH_BOOK_DAY_IMMUTABLE', 'nor deleted');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_sale(:'stu'::uuid, jsonb_build_array(jsonb_build_object('item_id', :'book', 'qty', 2)), 'cash') as r3 \gset
select is((select book_date from public.inv_sale where id = (:'r3'::jsonb ->> 'sale_id')::uuid), :'tomorrow'::date, 'a cash sale after the close is booked on the next open day');
select is((select amount_paisa from public.daily_collection_report(:'campus_id'::uuid, :'today'::date, :'today'::date) where mode = 'cash'), 308000::bigint, 'the closed day''s report does not change');
select is((select amount_paisa from public.daily_collection_report(:'campus_id'::uuid, :'tomorrow'::date, :'tomorrow'::date) where mode = 'cash'), 130000::bigint, 'the late sale shows on the next day''s report');
reset role;
update public.library_fine set status = 'outstanding' where loan_id = :'loan2'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.settle_library_fines(:'stu'::uuid, :'loan2'::uuid);
select is((select book_date from public.v_library_fine_cash_entry where campus_id = :'campus_id'::uuid and receipt_key = :'loan2' ), :'tomorrow'::date, 'a fine settled after the close is booked on the next open day');
select public.finalise_cash_book_day(:'campus_id'::uuid, :'tomorrow'::date);
select is((select opening_paisa || '/' || receipts_paisa || '/' || closing_paisa from public.cash_book_day where campus_id = :'campus_id'::uuid and book_date = :'tomorrow'::date), '188000/132500/320500', 'next day opens at the prior close and takes only its own receipts');
select is((select receipts_paisa from public.cash_book_day where campus_id = :'campus_id'::uuid and book_date = :'today'::date), 308000::bigint, 'the first day still reads as it was closed');

select * from finish();
rollback;
