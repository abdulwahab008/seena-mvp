-- pgTAP tests for FR-O06: FIFO reservation queue with hold expiry.
-- Also asserts the FR-O05 criterion that a returned copy with a waiting reservation becomes reserved_hold
-- for the head of the queue and cannot be taken by a walk-in.
begin;
select plan(37);

select public.provision_tenant('test-libres-co', 'Lib Reservation Co', 'owner@libres.test');
select id as tenant_id from public.tenant where slug = 'test-libres-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select public.provision_tenant('test-libres-other', 'Other Res Co', 'owner@otherlibres.test');
select id as other_tenant_id from public.tenant where slug = 'test-libres-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libres.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libres.test', 'authenticated', 'authenticated', 'x'),
  (:'lib_uid', 'l@libres.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@libres.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'lib_uid', :'tenant_id', 'librarian', 'Counter Librarian'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Borrowing Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'teach_uid', :'tenant_id', :'campus_id'), (:'lib_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Kid A', '2016-01-01'::date, 'male') as ka \gset
select public.create_student(:'campus_id'::uuid, 'Kid B', '2016-01-02'::date, 'male') as kb \gset
select public.create_student(:'campus_id'::uuid, 'Kid C', '2016-01-03'::date, 'male') as kc \gset
select public.create_student(:'campus_id'::uuid, 'Kid D', '2016-01-04'::date, 'male') as kd \gset
select public.create_student(:'campus_id'::uuid, 'Kid E', '2016-01-05'::date, 'male') as ke \gset
select public.enrol_student(:'sec'::uuid, k) from unnest(array[:'ka', :'kb', :'kc', :'kd', :'ke']::uuid[]) k;
select public.fn_find_or_create_guardian(p_name_en => 'Father A', p_phone_e164 => '+923006660001') as ga \gset
select public.link_guardian(:'ka'::uuid, :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Father B', p_phone_e164 => '+923006660002') as gb \gset
select public.link_guardian(:'kb'::uuid, :'gb'::uuid, 'father'::public.guardian_relationship, true, true);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 2, 14, 1, 500, '2026-01-01'::date, null, null, null, 50000, null);
select public.set_borrower_policy('teacher', 6, 30, 3, 0, '2026-01-01'::date);

reset role;
select gen_random_uuid() as par_a \gset
select gen_random_uuid() as stu_e \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'par_a', '923006660001', now(), 'x', 'authenticated', 'authenticated');
insert into auth.users (id, email, aud, role, encrypted_password) values (:'stu_e', 'e@libres.test', 'authenticated', 'authenticated', 'x');
update public.guardian set auth_user_id = :'par_a' where id = :'ga'::uuid;
insert into public.student_portal_account (tenant_id, campus_id, student_id, user_id) values (:'tenant_id', :'campus_id', :'ke', :'stu_e');
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics X') returning id as tx \gset
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Maths Z') returning id as tz \gset
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Spare Y') returning id as ty \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) select :'tenant_id', :'campus_id', :'tx', 'X-' || n, 'X' || n from generate_series(1, 3) n;
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) select :'tenant_id', :'campus_id', :'tz', 'Z-' || n, 'Z' || n from generate_series(1, 4) n;
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) values (:'tenant_id', :'campus_id', :'ty', 'Y-1', 'Y1');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- all 3 copies of X are out; B is at his loan limit
select public.issue_copy('X1', :'kc'::uuid);
select public.issue_copy('X2', :'kd'::uuid);
select public.issue_copy('X3', :'teach_uid'::uuid) as teach_loan \gset
select public.issue_copy('Z1', :'kb'::uuid);
select public.issue_copy('Z2', :'kb'::uuid);

-- ── AC1: FIFO queue, derived position ─────────────────────────────────────
select public.reserve_title(:'tx'::uuid, :'ka'::uuid) as resa \gset
select public.reserve_title(:'tx'::uuid, :'kb'::uuid) as resb \gset
select is((:'resa'::jsonb ->> 'queue_position')::int, 1, 'A is first in the queue');
select is((:'resb'::jsonb ->> 'queue_position')::int, 2, 'B is second');
select is((select queue_position from public.v_library_queue where id = (:'resb'::jsonb ->> 'reservation_id')::uuid), 2, 'position is derived from queued_at in a view');
select hasnt_column('public', 'library_reservation', 'position', 'no mutable position column exists to renumber');

-- ── AC4: duplicates; and only a title with no free copy can be reserved ───
select throws_ok(format($$ select public.reserve_title(%L, %L) $$, :'tx', :'ka'), 'DUPLICATE_RESERVATION', 'AC4: a second reservation of the same title is rejected with DUPLICATE_RESERVATION');
select throws_ok(format($$ select public.reserve_title(%L, %L) $$, :'ty', :'ka'), 'COPIES_AVAILABLE', 'a title with a free copy is borrowed, not reserved');
select is((select count(*) from public.library_reservation where borrower_id = :'kb'::uuid), 1::bigint, 'AC3: a borrower already at the loan limit can still reserve');

-- ── AC1 / FR-O05 AC4: the returned copy is held for the head of the queue ──
select public.return_copy('X1') as ret \gset
select is(:'ret'::jsonb ->> 'copy_status', 'reserved_hold', 'a returned copy with a waiting reservation becomes reserved_hold');
select is((select status::text from public.library_reservation where id = (:'resa'::jsonb ->> 'reservation_id')::uuid), 'held', 'A''s reservation is held');
select ok((select hold_expires_at between now() + interval '47 hours 55 minutes' and now() + interval '48 hours 5 minutes' from public.library_reservation where id = (:'resa'::jsonb ->> 'reservation_id')::uuid), 'the hold expires 48 hours later');
select is((select status::text from public.library_reservation where id = (:'resb'::jsonb ->> 'reservation_id')::uuid), 'waiting', 'B keeps waiting');
select is((select count(*) from public.message where idempotency_key = 'library_hold:' || (:'resa'::jsonb ->> 'reservation_id')), 1::bigint, 'A is notified through the SMS outbox');
select is((select recipient_phone from public.message where idempotency_key = 'library_hold:' || (:'resa'::jsonb ->> 'reservation_id')), '+923006660001', 'to the guardian''s phone');
reset role;
select is((select count(*) from public.user_notification where user_id = :'par_a'::uuid and kind = 'library_hold'), 1::bigint, 'and in the parent''s portal');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_copy('X1', %L) $$, :'ke'), 'COPY_NOT_AVAILABLE', 'a walk-in request for the held copy is refused');
select throws_ok(format($$ select public.issue_copy('X1', %L) $$, :'kb'), 'COPY_NOT_AVAILABLE', 'and so is the second in the queue');

-- ── AC2: expiry lapses A, promotes B with a fresh hold ────────────────────
reset role;
select is(public.expire_reservation_holds(), 0, 'nothing expires before the hold runs out');
update public.library_reservation set hold_expires_at = now() - interval '1 minute' where id = (:'resa'::jsonb ->> 'reservation_id')::uuid;
select is(public.expire_reservation_holds(), 1, 'AC2: the expiry job lapses the uncollected hold');
select is((select status::text from public.library_reservation where id = (:'resa'::jsonb ->> 'reservation_id')::uuid), 'lapsed', 'AC2: A''s reservation is lapsed');
select is((select status::text from public.library_reservation where id = (:'resb'::jsonb ->> 'reservation_id')::uuid), 'held', 'AC2: B is promoted');
select ok((select hold_expires_at > now() + interval '47 hours' from public.library_reservation where id = (:'resb'::jsonb ->> 'reservation_id')::uuid), 'AC2: with a fresh 48-hour hold');
select is((select status::text from public.library_copy where barcode = 'X1'), 'reserved_hold', 'the copy stays parked for B');
select is((select count(*) from public.library_loan where borrower_id = :'ka'::uuid), 0::bigint, 'AC2: the lapsed reservation counts as no loan for A');
select is(public.expire_reservation_holds(), 0, 'the job is idempotent');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.issue_copy('Z3', %L) $$, :'ka'), 'AC2: A can still borrow two other books after the lapse');
select lives_ok(format($$ select public.issue_copy('Z4', %L) $$, :'ka'), 'up to the limit of 2');

-- ── AC3: collection is subject to the loan limit ──────────────────────────
select throws_ok(format($$ select public.issue_copy('X1', %L) $$, :'kb'), 'LIMIT_EXCEEDED', 'AC3: B at the limit cannot collect the held copy');
select public.return_copy('Z1');
select lives_ok(format($$ select public.issue_copy('X1', %L) $$, :'kb'), 'AC3: after returning a book B collects it');
select is((select status::text from public.library_reservation where id = (:'resb'::jsonb ->> 'reservation_id')::uuid), 'collected', 'and the reservation is marked collected');

-- ── cancel, self-service, renew, access ───────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'stu_e', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reserve_title(:'tx'::uuid) as rese \gset
select is((select borrower_id from public.library_reservation where id = (:'rese'::jsonb ->> 'reservation_id')::uuid), :'ke'::uuid, 'a student reserves for themselves without naming a borrower');
select throws_ok(format($$ select public.reserve_title(%L, %L) $$, :'tx', :'kc'), 'FORBIDDEN', 'but not for another student');
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.renew_loan(%L) $$, :'teach_loan'::jsonb ->> 'loan_id'), 'RENEWAL_BLOCKED', 'a loan cannot be renewed while someone waits for the title');
select public.cancel_reservation((:'rese'::jsonb ->> 'reservation_id')::uuid);
select is((select status::text from public.library_reservation where id = (:'rese'::jsonb ->> 'reservation_id')::uuid), 'cancelled', 'a reservation can be cancelled');
select ok(public.renew_loan((:'teach_loan'::jsonb ->> 'loan_id')::uuid) > app.fn_karachi_today(), 'with nobody waiting the loan renews');
select throws_ok(format($$ select public.cancel_reservation(%L) $$, :'rese'::jsonb ->> 'reservation_id'), 'RESERVATION_NOT_FOUND', 'a finished reservation cannot be cancelled again');

select set_config('request.jwt.claims', json_build_object('sub', :'par_a', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.library_reservation), 1::bigint, 'a parent sees only their own child''s reservations');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_reservation), 0::bigint, 'another school sees none');

select * from finish();
rollback;
