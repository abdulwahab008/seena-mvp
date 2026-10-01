-- pgTAP tests for FR-O05: return a copy and capture its condition.
-- (The "returned copy with a waiting reservation becomes reserved_hold" criterion needs the reservation
-- queue of FR-O06 and is asserted in library_reservation.test.sql.)
begin;
select plan(29);

select public.provision_tenant('test-libret-co', 'Lib Return Co', 'owner@libret.test');
select id as tenant_id from public.tenant where slug = 'test-libret-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libret.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libret.test', 'authenticated', 'authenticated', 'x'),
  (:'lib_uid', 'l@libret.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@libret.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'lib_uid', :'tenant_id', 'librarian', 'Counter Librarian'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Borrowing Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'teach_uid', :'tenant_id', :'campus_id'), (:'lib_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Kid A', '2016-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'sec'::uuid, :'kid'::uuid);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 5, 14, 1, 500, '2026-01-01'::date, null, null, null, 50000, null);
select public.set_borrower_policy('teacher', 6, 30, 3, 500, '2026-01-01'::date, null, null, null, null, null, true);

reset role;
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics 9') returning id as title_id \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) select :'tenant_id', :'campus_id', :'title_id', 'ACC-' || n, 'BC' || n from generate_series(1, 10) n;
select app.fn_karachi_today() as today \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1 (+ O03 AC3): fine from the loan's policy snapshot ─────────────────
select public.issue_copy('BC1', :'kid'::uuid) as r1 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 5, 14, 1, 1000, :'today'::date, null, null, null, 50000, null);
reset role;
update public.library_loan set due_on = :'today'::date - 7 where id = (:'r1'::jsonb ->> 'loan_id')::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.return_copy('BC1') as ret1 \gset
select is((:'ret1'::jsonb ->> 'fine_amount')::bigint, 3500::bigint, 'AC1: 7 days late at PKR 5 a day is a finalised fine of PKR 35');
select is((select fine_amount from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), 3500::bigint, 'AC1: stamped on the loan');
select is((select sum(amount)::bigint from public.library_fine where loan_id = (:'r1'::jsonb ->> 'loan_id')::uuid), 3500::bigint, 'AC1: and written to the fine ledger');
select is((select count(*) from public.library_fine where loan_id = (:'r1'::jsonb ->> 'loan_id')::uuid), 7::bigint, 'AC1: one ledger row per late day');
select is((select (policy_snapshot ->> 'fine_per_day')::bigint from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), 500::bigint, 'O03 AC3: the raised PKR 10 rate did not re-price the loan (snapshot still PKR 5)');
select is((select status::text from public.library_copy where barcode = 'BC1'), 'available', 'a good return makes the copy available again');
select ok((select returned_at is not null and received_by = :'lib_uid'::uuid and return_condition = 'good' from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), 'the return records who received it and the condition');
select throws_ok($$ select public.return_copy('BC1') $$, 'NO_OPEN_LOAN', 'AC1: no accrual or second return is possible once closed');
select is((select count(*) from public.library_fine where loan_id = (:'r1'::jsonb ->> 'loan_id')::uuid), 7::bigint, 'AC1: the ledger is unchanged by the second attempt');

-- ── on-time return costs nothing ──────────────────────────────────────────
select public.issue_copy('BC2', :'kid'::uuid);
select is((public.return_copy('BC2') ->> 'fine_amount')::bigint, 0::bigint, 'an on-time return has no fine');

-- ── AC2: damaged goes to repair and leaves availability ───────────────────
select public.issue_copy('BC3', :'kid'::uuid);
select is((select available_copies from public.v_title_availability where title_id = :'title_id'::uuid), 9, 'before the damaged return: 9 of 10 available (BC3 is out)');
select is(public.return_copy('BC3', 'damaged') ->> 'copy_status', 'in_repair', 'AC2: a damaged return sends the copy to in_repair');
select is((select available_copies from public.v_title_availability where title_id = :'title_id'::uuid), 9, 'AC2: and it is excluded from the available count (a good return would make it 10)');
select throws_ok(format($$ select public.issue_copy('BC3', %L) $$, :'kid'), 'COPY_NOT_AVAILABLE', 'AC2: it cannot be issued while in repair');
select public.set_library_copy_status(id, 'available') from public.library_copy where barcode = 'BC3';
select is((select available_copies from public.v_title_availability where title_id = :'title_id'::uuid), 10, 'AC2: a librarian restoring it makes it count again');

-- ── AC3: scanning a copy with no open loan ────────────────────────────────
select throws_ok($$ select public.return_copy('BC4') $$, 'NO_OPEN_LOAN', 'AC3: a barcode with no open loan returns NO_OPEN_LOAN');
select is((select status::text from public.library_copy where barcode = 'BC4'), 'available', 'AC3: and changes no copy status');
select public.set_library_copy_status(id, 'in_repair') from public.library_copy where barcode = 'BC5';
select throws_ok($$ select public.return_copy('BC5') $$, 'NO_OPEN_LOAN', 'AC3: even for a copy in repair');
select is((select status::text from public.library_copy where barcode = 'BC5'), 'in_repair', 'AC3: it stays in repair');

-- ── fine cap ──────────────────────────────────────────────────────────────
select public.issue_copy('BC6', :'kid'::uuid) as r6 \gset
reset role;
update public.library_loan set due_on = :'today'::date - 300 where id = (:'r6'::jsonb ->> 'loan_id')::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.return_copy('BC6') ->> 'fine_amount')::bigint, 50000::bigint, 'a book 300 days late costs the PKR 500 cap, not PKR 1,500');

-- ── a return after the nightly job already accrued part of the fine ───────
select public.issue_copy('BC7', :'kid'::uuid) as r7 \gset
reset role;
update public.library_loan set due_on = :'today'::date - 7 where id = (:'r7'::jsonb ->> 'loan_id')::uuid;
select app.fn_library_accrue_loan((:'r7'::jsonb ->> 'loan_id')::uuid, :'today'::date - 3);
select is((select count(*) from public.library_fine where loan_id = (:'r7'::jsonb ->> 'loan_id')::uuid), 4::bigint, 'four fine days were already accrued by the nightly job');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.return_copy('BC7') ->> 'fine_amount')::bigint, 7000::bigint, 'the return tops it up to the full 7 days at the PKR 10 rate in this loan''s snapshot, without double counting');
select is((select count(*) from public.library_fine where loan_id = (:'r7'::jsonb ->> 'loan_id')::uuid), 7::bigint, 'one row per day, no duplicates');

-- ── working-days-only tenants ─────────────────────────────────────────────
select public.issue_copy('BC8', :'teach_uid'::uuid) as r8 \gset
reset role;
update public.library_loan set due_on = :'today'::date - 7 where id = (:'r8'::jsonb ->> 'loan_id')::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.return_copy('BC8') ->> 'fine_amount')::bigint, 3000::bigint, 'with working days only, the one Sunday in a 7-day lateness is not fined (6 x PKR 5)');

-- ── audit, validation, access ─────────────────────────────────────────────
reset role;
select ok(exists (select 1 from public.audit_log where table_name = 'library_loan' and row_id = (:'r1'::jsonb ->> 'loan_id')::uuid and action = 'update'), 'the return is recorded in the audit log');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.return_copy('BC9', 'torn') $$, 'INVALID_CONDITION', 'an unknown condition is refused');
select throws_ok($$ select public.return_copy('NOPE') $$, 'COPY_NOT_FOUND', 'an unknown barcode is reported');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.return_copy('BC9') $$, 'FORBIDDEN', 'a teacher cannot process returns');
select throws_ok($$ update public.library_loan set returned_at = now() $$, '42501', null, 'loans cannot be closed by a direct update');

select * from finish();
rollback;
