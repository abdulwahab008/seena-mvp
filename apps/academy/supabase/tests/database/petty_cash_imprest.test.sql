-- pgTAP tests for FR-L12: petty cash imprest and reconciliation.
begin;
select plan(30);

select public.provision_tenant('test-petty-co', 'Petty Co', 'owner@petty.test');
select id as tenant_id from public.tenant where slug = 'test-petty-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as head_id from public.expense_head where tenant_id = :'tenant_id' and code = 'STATIONERY' \gset
select public.provision_tenant('test-petty-other', 'Other Petty Co', 'owner@otherpetty.test');
select id as other_tenant_id from public.tenant where slug = 'test-petty-other' \gset
select id as other_head_id from public.expense_head where tenant_id = :'other_tenant_id' and code = 'STATIONERY' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as cust_uid \gset
select gen_random_uuid() as cust2_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@petty.test', 'authenticated', 'authenticated', 'x'), (:'cust_uid', 'c@petty.test', 'authenticated', 'authenticated', 'x'),
  (:'cust2_uid', 'c2@petty.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@petty.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@petty.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'cust_uid', :'tenant_id', 'accountant', 'Custodian One'), (:'cust2_uid', :'tenant_id', 'receptionist', 'Custodian Two'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_petty_cash_account(%L, 3000000, 3500000, %L) $$, :'campus_id', :'cust_uid'), '23514', null, 'a payment cap above the float is refused');
select public.create_petty_cash_account(:'campus_id'::uuid, 3000000::bigint, 500000::bigint, :'cust_uid'::uuid) as acct \gset
select throws_ok(format($$ select public.create_petty_cash_account(%L, 3000000, 500000, %L) $$, :'campus_id', :'cust_uid'), 'PETTY_CASH_ACCOUNT_EXISTS', 'a campus has one imprest account');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 3000000::bigint, 'the account opens at the float of 30,000');

-- ── AC1 and AC2: balance and per-transaction cap ──────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'cust_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Registers');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Printer paper');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Chalk');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Markers');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Files');
select public.post_petty_cash(:'acct'::uuid, 360000::bigint, :'head_id'::uuid, 'Staples');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 140000::bigint, 'six payments leave 1,400');
select public.post_petty_cash(:'acct'::uuid, 140000::bigint, :'head_id'::uuid, 'Cleaning cloths') ->> 'balance_after_paisa' as left_after \gset
select is(:'left_after'::bigint, 0::bigint, 'a payment of exactly the balance is allowed');
select throws_ok(format($$ select public.post_petty_cash(%L, 100, %L) $$, :'acct', :'head_id'), 'insufficient_petty_cash', 'AC1: a payment above the balance is rejected as insufficient_petty_cash');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 0::bigint, 'AC1: and the balance is unchanged');
select throws_ok(format($$ select public.post_petty_cash(%L, 700000, %L) $$, :'acct', :'head_id'), 'petty_cash_txn_cap_exceeded', 'AC2: a 7,000 expense is above the 5,000 cap');
select throws_ok(format($$ select public.post_petty_cash(%L, 0, %L) $$, :'acct', :'head_id'), 'AMOUNT_MUST_BE_POSITIVE', 'a zero payment is refused');
select throws_ok(format($$ select public.post_petty_cash(%L, 100, %L) $$, :'acct', :'other_head_id'), 'EXPENSE_HEAD_NOT_FOUND', 'another school''s expense head cannot be used');
select is(public.petty_cash_ledger_balance(:'acct'::uuid), 0::bigint, 'the ledger of movements adds up to the balance');

-- ── AC3: the count, variance and sign-off ─────────────────────────────────
-- put 4,200 back in the tin: replenish to float first, then spend down to 4,200
select public.request_petty_cash_replenishment(:'acct'::uuid, 0::bigint) as r0 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.decide_petty_cash_replenishment((:'r0'::jsonb ->> 'reconciliation_id')::uuid, true, 'Tin was empty');
select set_config('request.jwt.claims', json_build_object('sub', :'cust_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Furniture polish');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Pens');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Board cleaners');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Tape');
select public.post_petty_cash(:'acct'::uuid, 500000::bigint, :'head_id'::uuid, 'Glue');
select public.post_petty_cash(:'acct'::uuid, 80000::bigint, :'head_id'::uuid, 'Tea');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 420000::bigint, 'the tin holds 4,200 on the system');
select throws_ok(format($$ select public.request_petty_cash_replenishment(%L, 400000) $$, :'acct'), 'EXPLANATION_REQUIRED', 'AC3: a count that disagrees with the system needs an explanation');
select throws_ok(format($$ select public.request_petty_cash_replenishment(%L, 400000, 'short') $$, :'acct'), 'EXPLANATION_REQUIRED', 'AC3: and one of at least 20 characters');
select public.request_petty_cash_replenishment(:'acct'::uuid, 400000::bigint, 'Two 100 rupee notes unaccounted for, checking with the chowkidar') as r1 \gset
select is((:'r1'::jsonb ->> 'variance_paisa')::bigint, -20000::bigint, 'AC3: counted 4,000 against 4,200 is a variance of -200');
select is((:'r1'::jsonb ->> 'topup_paisa')::bigint, 2580000::bigint, 'the top-up that restores the float is 25,800');
select throws_ok(format($$ select public.post_petty_cash(%L, 100, %L) $$, :'acct', :'head_id'), 'RECONCILIATION_PENDING', 'the tin is frozen while the count waits for sign-off');
select throws_ok(format($$ select public.request_petty_cash_replenishment(%L, 400000, 'A second request for the same count') $$, :'acct'), 'RECONCILIATION_ALREADY_PENDING', 'there is one open count at a time');
select throws_ok(format($$ select public.decide_petty_cash_replenishment(%L, true) $$, (:'r1'::jsonb ->> 'reconciliation_id')), 'FORBIDDEN', 'the custodian cannot approve their own count');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 420000::bigint, 'nothing posts before the Principal signs off');

-- ── AC4: approval restores exactly the float ──────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.decide_petty_cash_replenishment((:'r1'::jsonb ->> 'reconciliation_id')::uuid, true, 'Shortfall noted, recover from tea fund') as d1 \gset
select is((:'d1'::jsonb ->> 'topup_paisa')::bigint, 2580000::bigint, 'AC4: a replenishment of 25,800 posts');
select is((select current_balance_paisa from public.petty_cash_account where id = :'acct'::uuid), 3000000::bigint, 'AC4: the balance is exactly the 30,000 float');
select is((select status from public.petty_cash_reconciliation where id = (:'r1'::jsonb ->> 'reconciliation_id')::uuid), 'closed', 'AC4: and the reconciliation is closed');
select is(public.petty_cash_ledger_balance(:'acct'::uuid), 3000000::bigint, 'every movement still adds up to the balance');
reset role;
select throws_ok($$ update public.petty_cash_txn set amount_paisa = 1 $$, '42501', null, 'a posted movement cannot be edited');
set local role authenticated;

-- ── custodian handover needs a count first ────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'cust_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_petty_cash(:'acct'::uuid, 100000::bigint, :'head_id'::uuid, 'Stamps');
select throws_ok(format($$ select public.change_petty_cash_custodian(%L, %L) $$, :'acct', :'cust2_uid'), 'RECONCILIATION_REQUIRED_BEFORE_HANDOVER', 'a tin with uncounted spending cannot change hands');
select public.request_petty_cash_replenishment(:'acct'::uuid, 2900000::bigint) as r2 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.decide_petty_cash_replenishment((:'r2'::jsonb ->> 'reconciliation_id')::uuid, true);
select lives_ok(format($$ select public.change_petty_cash_custodian(%L, %L) $$, :'acct', :'cust2_uid'), 'after a counted replenishment the handover is allowed');

-- ── access and isolation ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.post_petty_cash(%L, 100, %L) $$, :'acct', :'head_id'), 'FORBIDDEN', 'a teacher cannot spend from the tin');
select is((select count(*) from public.petty_cash_account), 0::bigint, 'and cannot see it');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.post_petty_cash(%L, 100, %L) $$, :'acct', :'other_head_id'), 'PETTY_CASH_ACCOUNT_NOT_FOUND', 'another school cannot reach this account');

select * from finish();
rollback;
