-- pgTAP tests for FR-L11: expense voucher approval chain.
--
-- Every one of this FR's controls is a database control, so almost all of
-- it is tested here: AC1's routing at each band BOUNDARY rather than
-- somewhere comfortably in the middle of a band, payment refused before
-- approval from all three callers the threat model names, AC2's ten-
-- character reason and the lock that follows a rejection, AC3's split
-- detection and the escalation of both the new voucher and its still-unpaid
-- siblings, and AC4's append-only trail tested as authenticated, as
-- service_role, as the table owner, and against TRUNCATE.
--
-- Amounts are paisa as bigint throughout, this codebase's money convention
-- (fee_ledger.amount_paisa, FR-K24's ACs). AC1's rupee figures are:
--
--   PKR  25,000 =  2,500,000 paisa    PKR 150,000 = 15,000,000 paisa
--   PKR  25,001 =  2,500,100 paisa    PKR 200,000 = 20,000,000 paisa
--   PKR  20,000 =  2,000,000 paisa    PKR 200,001 = 20,000,100 paisa
--
-- The paisa boundary between the self-approval band and the Principal band
-- is 2,500,000 / 2,500,001 — one paisa, not one rupee — and both sides of
-- it are asserted.
begin;
select plan(87);

select public.provision_tenant('test-expense-co', 'Expense Chain Co', 'owner@expense.test');
select id as tenant_id from public.tenant where slug = 'test-expense-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset

select id as head_util from public.expense_head where tenant_id = :'tenant_id' and code = 'UTILITIES' \gset
select id as head_rep  from public.expense_head where tenant_id = :'tenant_id' and code = 'REPAIRS' \gset
select id as head_adv  from public.expense_head where tenant_id = :'tenant_id' and code = 'CASH_ADVANCE' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@expense.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Expense Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@expense.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Nusrat Jamil');

select gen_random_uuid() as vp_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'vp_uid', 'vp@expense.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'vp_uid', :'tenant_id', 'vice_principal', 'Imran Sethi');

select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'acct_uid', 'accountant@expense.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'acct_uid', :'tenant_id', 'accountant', 'Farhat Jabeen');

-- A second campus, so the campus scope and the per-campus seeding both have
-- something to be wrong about.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.create_campus('SOUTH', 'Campus South', null) as _c \gset
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset

-- ═══════════════════════════════════════════════════════════════════════
-- Seeding: every campus is routed, from every path that creates one
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from public.approval_threshold where campus_id = :'campus_a'),
  3,
  'provision_tenant''s campus is seeded with AC1''s three bands'
);
select is(
  (select count(*)::int from public.approval_threshold where campus_id = :'campus_b'),
  3,
  'and so is a campus created later through create_campus()'
);
select results_eq(
  format($$ select min_amount_paisa, max_amount_paisa, required_role::text
              from public.approval_threshold where campus_id = %L order by min_amount_paisa $$, :'campus_b'),
  $$ values (0::bigint, 2500000::bigint, null::text),
            (2500001::bigint, 20000000::bigint, 'principal'),
            (20000001::bigint, null::bigint, 'owner') $$,
  'the bands are AC1''s, in paisa: self up to 25,000, Principal to 200,000, Owner above'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: routing, at the boundaries
-- ═══════════════════════════════════════════════════════════════════════

select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 1::bigint, :'head_util'::uuid),
  null::public.app_role,
  'AC1: one paisa is self-approved'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 2500000::bigint, :'head_util'::uuid),
  null::public.app_role,
  'AC1: PKR 25,000 exactly — the last paisa of the self-approval band — needs nobody above'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 2500001::bigint, :'head_util'::uuid),
  'principal'::public.app_role,
  'AC1: ONE PAISA more and it is the Principal''s'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 2500100::bigint, :'head_util'::uuid),
  'principal'::public.app_role,
  'AC1: PKR 25,001, the rupee boundary the AC states'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 15000000::bigint, :'head_util'::uuid),
  'principal'::public.app_role,
  'AC1: PKR 150,000 is the Principal''s'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 20000000::bigint, :'head_util'::uuid),
  'principal'::public.app_role,
  'AC1: PKR 200,000 exactly is still the Principal''s — the band is inclusive'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 20000001::bigint, :'head_util'::uuid),
  'owner'::public.app_role,
  'AC1: one paisa above PKR 200,000 is the Owner''s'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 20000100::bigint, :'head_util'::uuid),
  'owner'::public.app_role,
  'AC1: PKR 200,001, the rupee boundary the AC states'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 100000::bigint, :'head_adv'::uuid),
  'principal'::public.app_role,
  'a head that always needs sign-off raises a PKR 1,000 cash advance to the Principal'
);
select is(
  public.fn_required_approver_role(:'campus_a'::uuid, 20000100::bigint, :'head_adv'::uuid),
  'owner'::public.app_role,
  'and never LOWERS one — a PKR 200,001 cash advance is still the Owner''s'
);

-- A campus with a hole in its bands fails closed rather than open.
reset role;
delete from public.approval_threshold where campus_id = :'campus_b' and required_role = 'principal';
set local role authenticated;
select is(
  public.fn_required_approver_role(:'campus_b'::uuid, 15000000::bigint, :'head_util'::uuid),
  'owner'::public.app_role,
  'a campus whose middle band was deleted routes to the Owner, not to self-approval'
);
reset role;
insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role)
values (:'tenant_id', :'campus_b', 2500001, 20000000, 'principal');

select throws_ok(
  format($$ insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role)
            values (%L, %L, 10000000, 30000000, 'owner') $$, :'tenant_id', :'campus_b'),
  '23P01',
  null,
  'two bands cannot claim the same rupee — the routing decision is never the planner''s to make'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: a PKR 150,000 voucher reaches the Principal and CANNOT be paid
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);

select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'K-Electric',
  15000000::bigint, current_date, '1234567-8', 'August electricity', null, '203.0.113.9'
) as big \gset
select (:'big'::jsonb ->> 'voucher_id') as big_id \gset

select is(:'big'::jsonb ->> 'status', 'pending_approval',
  'AC1: a PKR 150,000 voucher is submitted into the queue, not approved');
select is(:'big'::jsonb ->> 'required_approver_role', 'principal',
  'AC1: and it is routed to the Principal');
select is(
  (select count(*)::int from public.expense_voucher_approval where voucher_id = :'big_id'),
  0,
  'AC1: with nothing in its approval trail yet'
);

-- It is in the Principal's queue, and nobody else's campus.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select isnt_empty(
  format($$ select 1 from public.v_expense_voucher
             where id = %L and status = 'pending_approval' and required_approver_role = 'principal' $$, :'big_id'),
  'AC1: the Principal sees it waiting in their pending queue'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_b'), 'sub', :'principal_uid')::text,
  true
);
select is_empty(
  format($$ select 1 from public.v_expense_voucher where id = %L $$, :'big_id'),
  'and a Principal of the other campus does not — expense_voucher_campus_scope'
);

-- AC1's "CANNOT be marked paid", from every caller.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select throws_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-0001') $$, :'big_id'),
  '55000',
  'VOUCHER_NOT_APPROVED',
  'AC1: an Accountant cannot pay a voucher that has not been approved'
);
select throws_ok(
  format($$ update public.expense_voucher set status = 'paid', paid_at = now() where id = %L $$, :'big_id'),
  '42501',
  'expense voucher transition refused',
  'AC1: nor reach ''paid'' by writing the column directly through PostgREST'
);

reset role;
set local role service_role;
select throws_ok(
  format($$ update public.expense_voucher set status = 'paid', paid_at = now() where id = %L $$, :'big_id'),
  '42501',
  'expense voucher transition refused',
  'AC1: a leaked service_role key cannot either — RLS is not what refuses'
);
select throws_ok(
  format($$ update public.expense_voucher set status = 'approved' where id = %L $$, :'big_id'),
  '42501',
  'expense voucher transition refused',
  'AC1: nor forge the approval that would make it payable'
);
reset role;
select throws_ok(
  format($$ update public.expense_voucher set status = 'paid', paid_at = now() where id = %L $$, :'big_id'),
  '42501',
  'expense voucher transition refused',
  'AC1: and neither can the table owner, writing the UPDATE by hand'
);
select throws_ok(
  format($$ update public.expense_voucher set amount_paisa = 100 where id = %L $$, :'big_id'),
  '42501',
  'expense voucher transition refused',
  'a submitted voucher''s amount is frozen — an editable amount makes any approval worthless'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'vice_principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'vp_uid')::text,
  true
);
select throws_ok(
  format($$ select public.decide_expense_voucher(%L, 'approved', null, '203.0.113.9') $$, :'big_id'),
  '42501',
  'APPROVER_RANK_INSUFFICIENT',
  'AC1: a Vice Principal cannot sign off a voucher the bands routed to the Principal'
);

-- The Principal approves, and only then can it be paid.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select lives_ok(
  format($$ select public.decide_expense_voucher(%L, 'approved', 'Bill checked against the meter reading.', '203.0.113.9') $$, :'big_id'),
  'AC1: the Principal approves it'
);
select is(
  (select status::text from public.expense_voucher where id = :'big_id'),
  'approved',
  'AC1: the voucher is approved'
);

-- AC4's four columns, on the approval that just happened.
select results_eq(
  format($$ select approver_id, approver_role::text, decision::text, host(request_ip)
              from public.expense_voucher_approval where voucher_id = %L $$, :'big_id'),
  format($$ values (%L::uuid, 'principal'::text, 'approved'::text, '203.0.113.9'::text) $$, :'principal_uid'),
  'AC4: approver id, role, decision and request IP are all on the approval row'
);
select ok(
  (select decided_at between now() - interval '1 minute' and clock_timestamp() + interval '1 minute'
     from public.expense_voucher_approval where voucher_id = :'big_id'),
  'AC4: and the timestamp of the decision'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select lives_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-0001') $$, :'big_id'),
  'AC1: and now — and only now — the Accountant can pay it'
);
select is(
  (select status::text from public.expense_voucher where id = :'big_id'),
  'paid',
  'AC1: the voucher is paid'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the trail is what makes a voucher payable, not the status column
-- ═══════════════════════════════════════════════════════════════════════

-- A voucher forced to 'approved' with an empty trail still cannot be paid:
-- the status guard's test is `does an approval of sufficient rank exist`,
-- which no amount of column-writing satisfies.
reset role;
insert into public.expense_voucher (
  tenant_id, campus_id, head_id, payee_name, payee_key, amount_paisa, voucher_date, created_by
) values (
  :'tenant_id', :'campus_a', :'head_rep', 'Forged Vendor', '', 15000000, current_date, :'acct_uid'
) returning id as forged_id \gset

select throws_ok(
  format($$ update public.expense_voucher set required_approver_role = null where id = %L $$, :'forged_id'),
  '42501',
  'expense voucher transition refused',
  'the routed role cannot be lowered after the fact to dodge the queue'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select throws_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-FORGE') $$, :'forged_id'),
  '55000',
  'VOUCHER_NOT_APPROVED',
  'a voucher written straight into the table is still pending, so it is still unpayable'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: rejection
-- ═══════════════════════════════════════════════════════════════════════

select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_rep'::uuid, 'Hafeez Builders',
  9000000::bigint, current_date, null, 'Roof repair', null, '198.51.100.20'
) as rej \gset
select (:'rej'::jsonb ->> 'voucher_id') as rej_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.decide_expense_voucher(%L, 'rejected', 'no', '198.51.100.20') $$, :'rej_id'),
  '23514',
  'REJECTION_REASON_TOO_SHORT',
  'AC2: a two-character reason is refused'
);
select throws_ok(
  format($$ select public.decide_expense_voucher(%L, 'rejected', 'too short', '198.51.100.20') $$, :'rej_id'),
  '23514',
  'REJECTION_REASON_TOO_SHORT',
  'AC2: and so is nine characters — the bar is ten'
);
select lives_ok(
  format($$ select public.decide_expense_voucher(%L, 'rejected', 'No quotes.', '198.51.100.20') $$, :'rej_id'),
  'AC2: exactly ten characters is accepted'
);
select is(
  (select status::text from public.expense_voucher where id = :'rej_id'),
  'rejected',
  'AC2: the status becomes rejected'
);

-- The CHECK constraint underneath, so no path can write a short reason even
-- if it never goes through decide_expense_voucher().
reset role;
select throws_ok(
  format($$ insert into public.expense_voucher_approval (tenant_id, voucher_id, approver_id, approver_role, decision, reason)
            values (%L, %L, %L, 'owner', 'rejected', 'nope') $$,
         :'tenant_id', :'rej_id', :'owner_uid'),
  '23514',
  null,
  'AC2: and the ten-character rule is a CHECK constraint, not only a function''s opinion'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select throws_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-0002') $$, :'rej_id'),
  '55000',
  'VOUCHER_NOT_APPROVED',
  'AC2: a rejected voucher is non-payable'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.decide_expense_voucher(%L, 'approved', 'On reflection.', '198.51.100.20') $$, :'rej_id'),
  '55000',
  'VOUCHER_NOT_PENDING',
  'AC2: not even the Owner can approve it back to life'
);
select throws_ok(
  format($$ update public.expense_voucher set narrative = 'Roof repair (revised)' where id = %L $$, :'rej_id'),
  '42501',
  'expense voucher transition refused',
  'AC2: and it is non-editable'
);
reset role;
select throws_ok(
  format($$ update public.expense_voucher set status = 'pending_approval' where id = %L $$, :'rej_id'),
  '42501',
  'expense voucher transition refused',
  'AC2: rejection is terminal for the table owner too — correction means a NEW voucher'
);

-- Resubmission as a new voucher is the sanctioned route, and it works.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select lives_ok(
  format($$ select public.submit_expense_voucher(%L, %L, 'Hafeez Builders',
              9000000::bigint, current_date - 1, null, 'Roof repair, three quotes attached', null, '198.51.100.20') $$,
         :'campus_a', :'head_rep'),
  'AC2: the fix is a new voucher, which submits normally'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the threshold split
-- ═══════════════════════════════════════════════════════════════════════

select (current_date - 3)::text as split_date \gset

select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'M/s Ali Traders',
  2000000::bigint, :'split_date'::date, null, 'Part one', null, '203.0.113.9'
) as sp1 \gset
select (:'sp1'::jsonb ->> 'voucher_id') as sp1_id \gset

select is(:'sp1'::jsonb ->> 'status', 'approved',
  'AC3: the first PKR 20,000 voucher is under the self-approval limit and self-approves');
select is(:'sp1'::jsonb ->> 'possible_threshold_split', 'false',
  'AC3: with nothing to be a split of, yet');
select is(
  (select count(*)::int from public.expense_voucher_approval
    where voucher_id = :'sp1_id' and decision = 'approved' and approver_role = 'accountant'),
  1,
  'a self-approval is still a signature: it is recorded on the trail with its approver and role'
);

-- The same shop, written the way a second clerk would write it.
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'm/s  ali traders.',
  2000000::bigint, :'split_date'::date, null, 'Part two', null, '203.0.113.9'
) as sp2 \gset
select (:'sp2'::jsonb ->> 'voucher_id') as sp2_id \gset

select is(:'sp2'::jsonb ->> 'possible_threshold_split', 'true',
  'AC3: the second PKR 20,000 voucher is flagged possible_threshold_split');
select is(:'sp2'::jsonb ->> 'required_approver_role', 'principal',
  'AC3: and ESCALATED to the Principal, though PKR 20,000 is below the self-approval limit');
select is(:'sp2'::jsonb ->> 'status', 'pending_approval',
  'AC3: so it waits in the queue instead of self-approving');

-- The decision this implementation makes beyond the AC's letter, and the
-- reason the control means anything: the first voucher has not been paid,
-- so it goes back into the queue too. Otherwise PKR 20,000 of a PKR 40,000
-- spend leaves the campus without the Principal ever seeing it.
select results_eq(
  format($$ select status::text, required_approver_role::text, possible_threshold_split
              from public.expense_voucher where id = %L $$, :'sp1_id'),
  $$ values ('pending_approval'::text, 'principal'::text, true) $$,
  'AC3: the FIRST voucher is pulled back out of ''approved'' and into the Principal''s queue'
);
select is(
  (select decision::text from public.expense_voucher_approval
    where voucher_id = :'sp1_id' order by decided_at desc limit 1),
  'escalated',
  'AC3: and the trail says why an approved voucher is back in the queue'
);
select ok(
  (select reason like '%threshold split%' and reason like '%4000000 paisa%'
     from public.expense_voucher_approval
    where voucher_id = :'sp1_id' and decision = 'escalated'),
  'AC3: naming the group and its total, in paisa'
);
select is(
  (select count(*)::int from public.expense_voucher_approval where voucher_id = :'sp1_id'),
  2,
  'AC3: the original self-approval is still on the trail beside the escalation — nothing was rewritten'
);

-- Paying the re-opened voucher on the strength of the old self-approval is
-- exactly what the escalation exists to stop.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select throws_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-SPLIT') $$, :'sp1_id'),
  '55000',
  'VOUCHER_NOT_APPROVED',
  'AC3: the superseded self-approval does not make the re-opened voucher payable'
);

-- A different day, or a different head, is a different spend.
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'M/s Ali Traders',
  2000000::bigint, (:'split_date'::date - 1), null, 'Another day', null, '203.0.113.9'
) as sp3 \gset
select is(:'sp3'::jsonb ->> 'possible_threshold_split', 'false',
  'AC3: the same payee and head on a DIFFERENT date is not a split');
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_rep'::uuid, 'M/s Ali Traders',
  2000000::bigint, :'split_date'::date, null, 'Different head', null, '203.0.113.9'
) as sp4 \gset
select is(:'sp4'::jsonb ->> 'possible_threshold_split', 'false',
  'AC3: and the same payee on the same date under a DIFFERENT head is not either');

-- An NTN is a real identity and beats any amount of string cleaning.
select (current_date - 4)::text as ntn_date \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Sharif Stationers',
  1500000::bigint, :'ntn_date'::date, '3456789-1', 'NTN one', null, '203.0.113.9'
) as ntn1 \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'SHARIF STATIONERS (PVT) LTD',
  1500000::bigint, :'ntn_date'::date, '3456789-1', 'NTN two', null, '203.0.113.9'
) as ntn2 \gset
select is(:'ntn2'::jsonb ->> 'possible_threshold_split', 'true',
  'AC3: two spellings of one shop are caught by the NTN, which no string cleaning could match');

-- The group TOTAL is what picks the escalated role, so a split big enough
-- to need the Owner gets the Owner and not merely the Principal.
select (current_date - 5)::text as big_split_date \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Metro Suppliers',
  12000000::bigint, :'big_split_date'::date, null, 'Half one', null, '203.0.113.9'
) as bg1 \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Metro Suppliers',
  12000000::bigint, :'big_split_date'::date, null, 'Half two', null, '203.0.113.9'
) as bg2 \gset
select is(:'bg1'::jsonb ->> 'required_approver_role', 'principal',
  'AC3: PKR 120,000 on its own is the Principal''s');
select is(:'bg2'::jsonb ->> 'required_approver_role', 'owner',
  'AC3: but two of them total PKR 240,000, so the split escalates to the OWNER, not the Principal');
select is(
  (select required_approver_role::text from public.expense_voucher where id = (:'bg1'::jsonb ->> 'voucher_id')::uuid),
  'owner',
  'AC3: and the first is raised to the Owner with it'
);

-- A voucher that has already been paid keeps its status. Un-paying it would
-- be rewriting what happened; the flag is what puts it in front of the
-- Principal reviewing the rest of the group.
select (current_date - 6)::text as paid_split_date \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Quick Cartage',
  2000000::bigint, :'paid_split_date'::date, null, 'Paid already', null, '203.0.113.9'
) as pd1 \gset
select (:'pd1'::jsonb ->> 'voucher_id') as pd1_id \gset
select lives_ok(
  format($$ select public.mark_expense_voucher_paid(%L, 'CHQ-PAID') $$, :'pd1_id'),
  'a self-approved PKR 20,000 voucher is paid'
);
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Quick Cartage',
  2000000::bigint, :'paid_split_date'::date, null, 'Second one', null, '203.0.113.9'
) as pd2 \gset
select results_eq(
  format($$ select status::text, possible_threshold_split from public.expense_voucher where id = %L $$, :'pd1_id'),
  $$ values ('paid'::text, true) $$,
  'AC3: an already-paid sibling is FLAGGED but stays paid — the money has left and the record says so'
);
select is(:'pd2'::jsonb ->> 'required_approver_role', 'principal',
  'AC3: and the new one is escalated anyway, so the rest of the split reaches the Principal');

-- A rejected sibling is money that is not going anywhere.
select (current_date - 7)::text as rej_split_date \gset
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Dead End Traders',
  15000000::bigint, :'rej_split_date'::date, null, 'Will be rejected', null, '203.0.113.9'
) as rs1 \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.decide_expense_voucher(
  (:'rs1'::jsonb ->> 'voucher_id')::uuid, 'rejected', 'Duplicate of last week.', '203.0.113.9') as _rs \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_util'::uuid, 'Dead End Traders',
  2000000::bigint, :'rej_split_date'::date, null, 'A real one', null, '203.0.113.9'
) as rs2 \gset
select is(:'rs2'::jsonb ->> 'possible_threshold_split', 'false',
  'AC3: a rejected sibling is not part of the group — that money is not going anywhere');

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the approval trail no role can update or delete
-- ═══════════════════════════════════════════════════════════════════════

select id as approval_id from public.expense_voucher_approval where voucher_id = :'big_id' \gset
select (select count(*)::int from public.expense_voucher_approval where tenant_id = :'tenant_id') as trail_before \gset

-- A Super Admin reaching Postgres as `authenticated`, which is how every
-- application role reaches it.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ update public.expense_voucher_approval set decision = 'rejected' where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: an authenticated Super Admin cannot turn an approval into a rejection'
);
select throws_ok(
  format($$ update public.expense_voucher_approval set approver_id = %L where id = %L $$, :'acct_uid', :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: nor move the signature on to somebody else'
);
select throws_ok(
  format($$ update public.expense_voucher_approval set request_ip = null where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: nor erase the address it came from'
);
select throws_ok(
  format($$ delete from public.expense_voucher_approval where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: nor delete it'
);

-- service_role has BYPASSRLS and every table grant, so the trigger is the
-- only thing standing there.
reset role;
set local role service_role;
select throws_ok(
  format($$ update public.expense_voucher_approval set decision = 'rejected' where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: a leaked service_role key cannot either — RLS is not what refuses'
);
select throws_ok(
  format($$ delete from public.expense_voucher_approval where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: and its DELETE is refused by the row trigger'
);

-- And the table's own owner, hand-writing the statement.
reset role;
select throws_ok(
  format($$ update public.expense_voucher_approval set decided_at = now() - interval '1 year' where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: even the table owner is refused — there is no sanctioned update to fall into'
);
select throws_ok(
  format($$ delete from public.expense_voucher_approval where id = %L $$, :'approval_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: and so is the owner''s DELETE'
);
select throws_ok(
  format($$ delete from public.expense_voucher where id = %L $$, :'big_id'),
  '42501',
  'expense approval trail is append-only',
  'AC4: deleting the voucher would cascade into the trail, so that is refused too'
);
-- TRUNCATE fires no row trigger and consults no RLS policy at all.
select throws_ok(
  $$ truncate table public.expense_voucher_approval $$,
  '42501',
  'expense approval trail is append-only',
  'AC4: TRUNCATE, which no row trigger and no RLS policy would ever see, is refused by its own'
);
select throws_ok(
  $$ truncate table public.expense_voucher_approval cascade $$,
  '42501',
  'expense approval trail is append-only',
  'AC4: and so is TRUNCATE CASCADE'
);
-- 20260731999100 gave expense_voucher a TRUNCATE guard of its own, so a
-- cascade from the voucher table is now refused one relation earlier than
-- it used to be — by the voucher's guard rather than the trail's. Either
-- refusal aborts the whole statement, and the count assertion below still
-- proves the trail survived a TRUNCATE aimed at its parent.
select throws_ok(
  $$ truncate table public.expense_voucher cascade $$,
  '42501',
  'table public.expense_voucher cannot be truncated',
  'AC4: including one that reaches the trail by cascading from the voucher table'
);

select is(
  (select count(*)::int from public.expense_voucher_approval where tenant_id = :'tenant_id'),
  :trail_before,
  'AC4: after thirteen attempts from three different callers the trail is exactly as it was'
);
select results_eq(
  format($$ select decision::text, approver_role::text, host(request_ip)
              from public.expense_voucher_approval where id = %L $$, :'approval_id'),
  $$ values ('approved'::text, 'principal'::text, '203.0.113.9'::text) $$,
  'AC4: and the row under attack is byte-for-byte what the Principal signed'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the IP, and its honest absence
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_rep'::uuid, 'No Header Vendor',
  100000::bigint, current_date, null, 'Direct request', null, null
) as noip \gset
select is(
  (select request_ip from public.expense_voucher_approval
    where voucher_id = (:'noip'::jsonb ->> 'voucher_id')::uuid),
  null::inet,
  'AC4: a request that carried no forwarded address records NULL, not a fabricated one'
);
select public.submit_expense_voucher(
  :'campus_a'::uuid, :'head_rep'::uuid, 'Garbage Header Vendor',
  100000::bigint, current_date, null, 'Nonsense header', null, 'not-an-ip-address'
) as badip \gset
select is(
  (select request_ip from public.expense_voucher_approval
    where voucher_id = (:'badip'::jsonb ->> 'voucher_id')::uuid),
  null::inet,
  'AC4: and an unparseable one records NULL rather than raising and losing the approval'
);
select is(
  (select host(request_ip) from public.expense_voucher_approval
    where voucher_id = (:'sp1_id')::uuid and decision = 'approved'),
  '203.0.113.9',
  'AC4: an IPv6 or IPv4 address that parses is stored as inet'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Submission guards
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.submit_expense_voucher(%L, %L, 'Future Vendor',
              100000::bigint, current_date + 1, null, null, null, null) $$, :'campus_a', :'head_util'),
  '23514',
  'VOUCHER_DATE_INVALID',
  'a voucher cannot be dated in the future'
);
select throws_ok(
  format($$ select public.submit_expense_voucher(%L, %L, '   ',
              100000::bigint, current_date, null, null, null, null) $$, :'campus_a', :'head_util'),
  '23514',
  'VOUCHER_PAYEE_REQUIRED',
  'and it has to name a payee'
);
select throws_ok(
  format($$ select public.submit_expense_voucher(%L, %L, 'Other Campus Vendor',
              100000::bigint, current_date, null, null, null, null) $$, :'campus_b', :'head_util'),
  '42501',
  'FORBIDDEN',
  'an Accountant cannot raise a voucher against a campus they are not posted to'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'acct_uid')::text,
  true
);
select throws_ok(
  format($$ select public.submit_expense_voucher(%L, %L, 'Teacher Vendor',
              100000::bigint, current_date, null, null, null, null) $$, :'campus_a', :'head_util'),
  '42501',
  'FORBIDDEN',
  'and a Class Teacher cannot raise one at all'
);

select * from finish();
rollback;
