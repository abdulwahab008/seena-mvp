-- pgTAP tests for FR-O08: lost copy write-off and recovery charge.
begin;
select plan(41);

select public.provision_tenant('test-libwo-co', 'Lib WriteOff Co', 'owner@libwo.test');
select id as tenant_id from public.tenant where slug = 'test-libwo-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select public.provision_tenant('test-libwo-other', 'Other WO Co', 'owner@otherlibwo.test');
select id as other_tenant_id from public.tenant where slug = 'test-libwo-other' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'JT', 'Johar Town') returning id as johar_id \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as lib_jt_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libwo.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libwo.test', 'authenticated', 'authenticated', 'x'),
  (:'lib_uid', 'l@libwo.test', 'authenticated', 'authenticated', 'x'), (:'lib_jt_uid', 'lj@libwo.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@libwo.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@libwo.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'),
  (:'lib_jt_uid', :'tenant_id', 'librarian', 'JT Librarian'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Borrowing Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'lib_uid', :'tenant_id', :'campus_id'), (:'lib_jt_uid', :'tenant_id', :'johar_id'), (:'acct_uid', :'tenant_id', :'campus_id'), (:'teach_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Kid A', '2016-01-01'::date, 'male') as ka \gset
select public.create_student(:'campus_id'::uuid, 'Kid B', '2016-01-02'::date, 'male') as kb \gset
select public.enrol_student(:'sec'::uuid, k) as enrol from unnest(array[:'ka', :'kb']::uuid[]) k;
select id as enrol_a from public.enrolment where student_id = :'ka'::uuid \gset
select public.fn_find_or_create_guardian(p_name_en => 'Father A', p_phone_e164 => '+923008880001') as ga \gset
select public.link_guardian(:'ka'::uuid, :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 5, 14, 1, 500, '2026-01-01'::date, null, null, null, null, null);
select public.set_borrower_policy('teacher', 6, 30, 3, 0, '2026-01-01'::date);

reset role;
select gen_random_uuid() as par_a \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'par_a', '923008880001', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'par_a' where id = :'ga'::uuid;
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics X') returning id as tx \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode, purchase_cost) values
  (:'tenant_id', :'campus_id', :'tx', 'LIB-2024-00099', 'W1', 85000), (:'tenant_id', :'campus_id', :'tx', 'LIB-2024-00100', 'W2', 85000),
  (:'tenant_id', :'campus_id', :'tx', 'LIB-2024-00101', 'W3', 85000), (:'tenant_id', :'campus_id', :'tx', 'LIB-2024-00102', 'W4', 85000),
  (:'tenant_id', :'campus_id', :'tx', 'LIB-2024-00103', 'W5', null);
select id as w1 from public.library_copy where barcode = 'W1' \gset
select id as w2 from public.library_copy where barcode = 'W2' \gset
select id as w3 from public.library_copy where barcode = 'W3' \gset
select id as w4 from public.library_copy where barcode = 'W4' \gset
select id as w5 from public.library_copy where barcode = 'W5' \gset
select app.fn_karachi_today() as today \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_copy('W1', :'ka'::uuid) as loan1 \gset
select public.issue_copy('W3', :'teach_uid'::uuid) as loan3 \gset
reset role;
-- W1 is 24 days overdue at PKR 5 a day = PKR 120 of accrued fine
update public.library_loan set due_on = :'today'::date - 24 where id = (:'loan1'::jsonb ->> 'loan_id')::uuid;
select public.accrue_library_fines(:'today'::date);
select sum(amount)::bigint as accrued from public.library_fine where loan_id = (:'loan1'::jsonb ->> 'loan_id')::uuid \gset
select is(:'accrued'::bigint, 12000::bigint, 'precondition: PKR 120 of accrued fine');
select public.student_balance(:'enrol_a'::uuid) as bal_before \gset
set local role authenticated;

-- ── AC1: PKR 850 x 1.5 + PKR 120 fine = PKR 1,395, one charge ─────────────
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.write_off_copy(:'w1'::uuid, 'multiple', 1.5) as wo1 \gset
select is((:'wo1'::jsonb ->> 'ok')::boolean, true, 'the write-off succeeds');
select is((:'wo1'::jsonb ->> 'charge_amount')::bigint, 139500::bigint, 'AC1: charge = 850 x 1.5 + 120 = PKR 1,395');
select is((select count(*) from public.fee_ledger where source_type = 'library_write_off' and source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), 1::bigint, 'AC1: a single ledger entry is posted');
select is((select amount_paisa from public.fee_ledger where source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), 139500::bigint, 'AC1: for PKR 1,395');
select is((select h.code from public.fee_ledger l join public.fee_head h on h.id = l.fee_head_id where l.source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), 'LIB_RECOVERY', 'AC1: under head LIB_RECOVERY');
select is((select direction::text from public.fee_ledger where source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), 'debit', 'AC1: as a debit on the student''s account');
select is((select enrolment_id from public.fee_ledger where source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), :'enrol_a'::uuid, 'AC1: on the same fee ledger (the borrower''s enrolment)');
reset role;
select is(public.student_balance(:'enrol_a'::uuid) - :'bal_before'::bigint, 139500::bigint, 'the student''s balance (derived from the ledger) rises by PKR 1,395');
select is((select status::text from public.library_copy where id = :'w1'::uuid), 'written_off', 'the copy is written off');
select ok((select returned_at is not null and return_condition = 'lost' from public.library_loan where id = (:'loan1'::jsonb ->> 'loan_id')::uuid), 'the loan is closed as lost');
select is((select count(*) from public.library_fine where loan_id = (:'loan1'::jsonb ->> 'loan_id')::uuid and status = 'settled' and write_off_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), 24::bigint, 'the loan''s fines are settled by the write-off (they are inside the charge)');
select ok(exists (select 1 from public.audit_log where table_name = 'library_write_off' and row_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid and action = 'insert'), 'the write-off is in the audit log');
select is((select count(*) from public.message where idempotency_key = 'library_writeoff:' || (:'wo1'::jsonb ->> 'write_off_id')), 1::bigint, 'the guardian is told');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.write_off_copy(%L) $$, :'w1'), 'WRITE_OFF_EXISTS', 'a copy cannot be written off twice');

-- ── AC3: the accession number is never reusable ───────────────────────────
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'LIB-2024-00099', 'NEWBC') $$, :'tx', :'campus_id'), 'DUPLICATE_ACCESSION', 'AC3: LIB-2024-00099 cannot be reused by a new copy');

-- ── AC2: the copy is found: reverse by credit note ────────────────────────
select public.reverse_write_off((:'wo1'::jsonb ->> 'write_off_id')::uuid, 'Book found behind the shelf') as rev1 \gset
select is((:'rev1'::jsonb ->> 'ok')::boolean, true, 'AC2: the write-off is reversed');
select is((select status::text from public.library_copy where id = :'w1'::uuid), 'available', 'AC2: the copy returns to available');
select is((select count(*) from public.fee_ledger where source_id = (:'wo1'::jsonb ->> 'write_off_id')::uuid and entry_type = 'charge'), 1::bigint, 'AC2: the original charge row remains');
select is((select count(*) from public.fee_ledger where reversal_of_id = (select fee_ledger_id from public.library_write_off where id = (:'wo1'::jsonb ->> 'write_off_id')::uuid)), 1::bigint, 'AC2: and a credit note references it');
select is((select direction::text || ':' || amount_paisa from public.fee_ledger where id = (:'rev1'::jsonb ->> 'credit_note_id')::uuid), 'credit:139500', 'AC2: reversing the full PKR 1,395');
select is((select count(*) from public.library_write_off where copy_id = :'w1'::uuid), 2::bigint, 'AC2: the write-off row and its reversal are both kept');
select is((select reversed_at is not null from public.library_write_off where id = (:'wo1'::jsonb ->> 'write_off_id')::uuid), true, 'the original is stamped reversed');
reset role;
select is(public.student_balance(:'enrol_a'::uuid), :'bal_before'::bigint, 'the balance is back to where it started');
select is((select count(*) from public.library_fine where loan_id = (:'loan1'::jsonb ->> 'loan_id')::uuid and status = 'outstanding'), 24::bigint, 'the late fines are owed again after the reversal');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.reverse_write_off(%L) $$, :'wo1'::jsonb ->> 'write_off_id'), 'ALREADY_REVERSED', 'a write-off can be reversed only once');
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'LIB-2024-00099', 'NEWBC') $$, :'tx', :'campus_id'), 'DUPLICATE_ACCESSION', 'AC3: the accession number is still taken after the reversal');

-- ── other bases, other borrowers ──────────────────────────────────────────
select is((public.write_off_copy(:'w2'::uuid, 'multiple', 1.5) ->> 'charge_amount')::bigint, 0::bigint, 'a copy lost from the shelf with no open loan is written off at no charge');
select is((public.write_off_copy(:'w3'::uuid, 'purchase_cost') ->> 'charge_amount')::bigint, 85000::bigint, 'the purchase_cost basis charges the plain cost (PKR 850)');
select is((select count(*) from public.fee_ledger where source_type = 'library_write_off'), 1::bigint, 'a staff borrower''s recovery is not posted to a student fee ledger');
select ok((select recovery_note like 'Staff borrower%' from public.library_write_off where copy_id = :'w3'::uuid), 'it is recorded on the write-off for payroll recovery');
select throws_ok(format($$ select public.write_off_copy(%L, 'market') $$, :'w4'), 'MARKET_VALUE_REQUIRED', 'the market basis needs a value');
select throws_ok(format($$ select public.write_off_copy(%L, 'multiple') $$, :'w5'), 'PURCHASE_COST_MISSING', 'a copy with no purchase cost cannot be priced by multiple');

-- ── AC4: roles ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.write_off_copy(:'w4'::uuid, 'purchase_cost') ->> 'error', 'FORBIDDEN', 'AC4: a teacher''s write-off is refused');
reset role;
select is((select status::text from public.library_copy where id = :'w4'::uuid), 'available', 'AC4: and changes nothing');
select ok(exists (select 1 from public.audit_log where table_name = 'library_write_off:denied' and actor_user_id = :'teach_uid'::uuid and row_id = :'w4'::uuid), 'AC4: the refused attempt is recorded in the audit log');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.write_off_copy(:'w4'::uuid, 'purchase_cost') ->> 'error', 'FORBIDDEN', 'an accountant cannot write a copy off either, but can read the register');
select cmp_ok((select count(*) from public.library_write_off), '>=', 3::bigint, 'the accountant sees the write-offs');
select set_config('request.jwt.claims', json_build_object('sub', :'lib_jt_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'johar_id'))::text, true);
select throws_ok(format($$ select public.write_off_copy(%L, 'purchase_cost') $$, :'w4'), 'CAMPUS_NOT_ALLOWED', 'a librarian of another campus cannot write off this campus''s copy');
select set_config('request.jwt.claims', json_build_object('sub', :'par_a', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.library_write_off), 2::bigint, 'a parent sees the write-off (and its reversal) of their own child');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_write_off), 0::bigint, 'another school sees none');

select * from finish();
rollback;
