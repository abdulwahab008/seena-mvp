-- pgTAP tests for FR-O07: nightly overdue fine accrual job.
begin;
select plan(32);

select public.provision_tenant('test-libfine-co', 'Lib Fine Co', 'owner@libfine.test');
select id as tenant_id from public.tenant where slug = 'test-libfine-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select public.provision_tenant('test-libfine-other', 'Other Fine Co', 'owner@otherlibfine.test');
select id as other_tenant_id from public.tenant where slug = 'test-libfine-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libfine.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libfine.test', 'authenticated', 'authenticated', 'x'),
  (:'lib_uid', 'l@libfine.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@libfine.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@libfine.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'),
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'lib_uid', :'tenant_id', :'campus_id'), (:'acct_uid', :'tenant_id', :'campus_id'), (:'teach_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Kid A', '2016-01-01'::date, 'male') as ka \gset
select public.create_student(:'campus_id'::uuid, 'Kid B', '2016-01-02'::date, 'male') as kb \gset
select public.create_student(:'campus_id'::uuid, 'Kid C', '2016-01-03'::date, 'male') as kc \gset
select public.create_student(:'campus_id'::uuid, 'Kid D', '2016-01-04'::date, 'male') as kd \gset
select public.enrol_student(:'sec'::uuid, k) from unnest(array[:'ka', :'kb', :'kc', :'kd']::uuid[]) k;
select public.fn_find_or_create_guardian(p_name_en => 'Father C', p_phone_e164 => '+923007770003') as gc \gset
select public.link_guardian(:'kc'::uuid, :'gc'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Father A', p_phone_e164 => '+923007770001') as ga \gset
select public.link_guardian(:'ka'::uuid, :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 5, 14, 1, 500, '2026-01-01'::date, null, null, null, 50000, 30000);

reset role;
select gen_random_uuid() as par_a \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'par_a', '923007770001', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'par_a' where id = :'ga'::uuid;
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics X') returning id as tx \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode, status) select :'tenant_id', :'campus_id', :'tx', 'ACC-' || n, 'BC' || n, 'issued' from generate_series(1, 6) n;
select app.fn_karachi_today() as today \gset
select to_jsonb(p) as snap from public.library_borrower_policy p where p.tenant_id = :'tenant_id' and p.role = 'student' \gset

-- open loans, each overdue by a different amount (inserted directly: the counter RPC would not allow a past due date)
create temp table loans (n int, borrower uuid, days_over int);
grant all on loans to public;
insert into loans values (1, :'ka', 6), (2, :'kb', 300), (3, :'kc', 100), (4, :'kd', -3);
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, issued_at, due_on, policy_snapshot)
select :'tenant_id', :'campus_id', c.id, l.borrower, 'student', now() - interval '90 days', :'today'::date - l.days_over, :'snap'::jsonb
  from loans l join public.library_copy c on c.barcode = 'BC' || l.n;
select id as loan_a from public.library_loan where borrower_id = :'ka'::uuid \gset
select id as loan_b from public.library_loan where borrower_id = :'kb'::uuid \gset
select id as loan_c from public.library_loan where borrower_id = :'kc'::uuid \gset
select id as loan_d from public.library_loan where borrower_id = :'kd'::uuid \gset

-- ── AC1: 6 days overdue at PKR 5 a day ────────────────────────────────────
select public.accrue_library_fines(:'today'::date) as run1 \gset
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_a'::uuid), 3000::bigint, 'AC1: a loan 6 days overdue at PKR 5 a day shows PKR 30 on the ledger');
select is((select count(*) from public.library_fine where loan_id = :'loan_a'::uuid), 6::bigint, 'one ledger row per day');
select is((select days_overdue from public.library_fine where loan_id = :'loan_a'::uuid order by accrual_date desc limit 1), 6, 'the last row says 6 days overdue');
select is((select count(*) from public.library_fine where loan_id = :'loan_d'::uuid), 0::bigint, 'a loan not yet due accrues nothing');

-- ── AC2: re-runs are idempotent ───────────────────────────────────────────
select public.accrue_library_fines(:'today'::date);
select public.accrue_library_fines(:'today'::date);
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_a'::uuid), 3000::bigint, 'AC2: after two re-runs the ledger still shows PKR 30');
select is((select count(*) from public.library_fine where loan_id = :'loan_a'::uuid), 6::bigint, 'AC2: and the unique index prevented duplicate rows');
reset role;
select throws_ok(format($$ insert into public.library_fine (tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount) select tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount from public.library_fine where loan_id = %L limit 1 $$, :'loan_a'), '23505', null, 'AC2: a duplicate (loan, day) row is refused by uq_fine_per_loan_day');

-- ── the cap ───────────────────────────────────────────────────────────────
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_b'::uuid), 50000::bigint, 'AC3: a loan 300 days overdue is capped at PKR 500, not PKR 1,500');
select is((select count(*) from public.library_fine where loan_id = :'loan_b'::uuid), 100::bigint, 'AC3: the cap stops accrual after 100 days of PKR 5');
select public.accrue_library_fines(:'today'::date + 1);
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_b'::uuid), 50000::bigint, 'AC3: the next night adds nothing once capped');
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_a'::uuid), 3500::bigint, 'the next night adds the 7th day for the 6-day loan');

-- ── a missed night is healed by the next run ──────────────────────────────
reset role;
update public.library_loan set due_on = :'today'::date - 4 where id = :'loan_d'::uuid;
select public.accrue_library_fines(:'today'::date - 2);
select is((select count(*) from public.library_fine where loan_id = :'loan_d'::uuid), 2::bigint, 'a job that only ran up to two days ago has two rows');
select public.accrue_library_fines(:'today'::date);
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_d'::uuid), 2000::bigint, 'the next run catches up the days it missed (4 x PKR 5), never skipping or doubling a day');

-- ── AC4: blocked borrowers ────────────────────────────────────────────────
select is((select is_blocked from public.v_borrower_outstanding_fine where borrower_id = :'kc'::uuid), true, 'AC4: a borrower over the PKR 300 threshold is flagged blocked (PKR 500 outstanding)');
select is((select is_blocked from public.v_borrower_outstanding_fine where borrower_id = :'ka'::uuid), false, 'AC4: PKR 35 outstanding is under the threshold, so that borrower is not blocked');
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) values (:'tenant_id', :'campus_id', :'tx', 'ACC-FREE', 'FREE1');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_copy('FREE1', %L) $$, :'kc'), 'BORROWER_BLOCKED', 'AC4: subsequent issue attempts by the blocked borrower are refused');
select lives_ok(format($$ select public.issue_copy('FREE1', %L) $$, :'ka'), 'a borrower under the threshold can still borrow');
reset role;
select ok((select count(*) from public.message where idempotency_key = 'library_block:' || :'kc' || ':' || :'today') = 1, 'AC4: the newly blocked borrower''s guardian is notified, once');

-- ── returned loans no longer accrue ───────────────────────────────────────
update public.library_loan set returned_at = now() where id = :'loan_c'::uuid;
select is((select fine_amount from public.library_loan where id = :'loan_c'::uuid), 50000::bigint, 'a return finalises the fine at the cap');
select public.accrue_library_fines(:'today'::date + 5);
select is((select sum(amount)::bigint from public.library_fine where loan_id = :'loan_c'::uuid), 50000::bigint, 'and the job leaves a returned loan alone');

-- ── settle / waive by the Accountant ──────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.settle_library_fines(%L) $$, :'kc'), 'FORBIDDEN', 'a librarian cannot settle fines');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.settle_library_fines(:'kc'::uuid, null, gen_random_uuid()), 50000::bigint, 'the Accountant settles the borrower''s outstanding fines');
select is((select count(*) from public.library_fine where borrower_id = :'kc'::uuid and status = 'outstanding'), 0::bigint, 'nothing is left outstanding');
select is((select count(*) from public.v_borrower_outstanding_fine where borrower_id = :'kc'::uuid), 0::bigint, 'and the borrower is no longer blocked');
select throws_ok(format($$ select public.waive_library_fines(%L, 'no') $$, :'kb'), 'REASON_REQUIRED', 'a waiver needs a written reason');
select is(public.waive_library_fines(:'kb'::uuid, 'Hardship case approved by the Principal'), 50000::bigint, 'with a reason the fines are waived');
select is((select count(*) from public.library_fine where borrower_id = :'kb'::uuid and status = 'waived' and waive_reason is not null and waived_by = :'acct_uid'::uuid), 100::bigint, 'recording who waived and why');
reset role;
select throws_ok(format($$ delete from public.library_fine where loan_id = %L $$, :'loan_b'), 'LIBRARY_FINE_NOT_DELETABLE', 'fine rows can never be deleted');

-- ── visibility ────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par_a', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select ok((select count(*) from public.library_fine) > 0 and (select count(*) from public.library_fine where borrower_id <> :'ka'::uuid) = 0, 'a parent sees only their own child''s fines');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.library_fine), 0::bigint, 'a teacher sees no fines');
select throws_ok($$ select public.accrue_library_fines() $$, '42501', null, 'the job is not callable by clients');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_fine), 0::bigint, 'another school sees no fines');

select * from finish();
rollback;
