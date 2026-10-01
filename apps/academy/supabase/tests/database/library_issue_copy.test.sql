-- pgTAP tests for FR-O04 (issue copy with limit enforcement). Also asserts the FR-O02 criterion
-- that a copy in status lost cannot be issued, and the FR-O03 loan-time policy snapshot.
begin;
select plan(29);

select public.provision_tenant('test-libissue-co', 'Lib Issue Co', 'owner@libissue.test');
select id as tenant_id from public.tenant where slug = 'test-libissue-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select public.provision_tenant('test-libissue-other', 'Other Issue Co', 'owner@otherlibissue.test');
select id as other_tenant_id from public.tenant where slug = 'test-libissue-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libissue.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libissue.test', 'authenticated', 'authenticated', 'x'),
  (:'lib_uid', 'l@libissue.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@libissue.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'lib_uid', :'tenant_id', 'librarian', 'Counter Librarian'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Borrowing Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'teach_uid', :'tenant_id', :'campus_id'), (:'lib_uid', :'tenant_id', :'campus_id');

create function pg_temp.err_detail(p_sql text) returns text language plpgsql as $$
declare d text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics d = pg_exception_detail;
  return d;
end;
$$;
grant execute on function pg_temp.err_detail(text) to public;
create function pg_temp.elapsed_ms(p_sql text) returns numeric language plpgsql as $$
declare t0 timestamptz := clock_timestamp();
begin
  execute p_sql;
  return extract(epoch from clock_timestamp() - t0) * 1000;
end;
$$;
grant execute on function pg_temp.elapsed_ms(text) to public;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Kid A', '2016-01-01'::date, 'male') as kid_a \gset
select public.enrol_student(:'sec'::uuid, :'kid_a'::uuid);
select public.create_student(:'campus_id'::uuid, 'Kid B', '2016-02-01'::date, 'female') as kid_b \gset
select public.enrol_student(:'sec'::uuid, :'kid_b'::uuid);
select public.create_student(:'campus_id'::uuid, 'Kid C', '2016-03-01'::date, 'male') as kid_c \gset
select public.enrol_student(:'sec'::uuid, :'kid_c'::uuid);
select public.fn_find_or_create_guardian(p_name_en => 'Father A', p_phone_e164 => '+923005550001') as g1 \gset
select public.link_guardian(:'kid_a'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Father B', p_phone_e164 => '+923005550002') as g2 \gset
select public.link_guardian(:'kid_b'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 2, 14, 1, 500, '2026-01-01'::date, null, null, null, 50000, 30000);
select public.set_borrower_policy('teacher', 6, 30, 3, 0, '2026-01-01'::date);

reset role;
select gen_random_uuid() as par1 \gset
select gen_random_uuid() as par2 \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values
  (:'par1', '923005550001', now(), 'x', 'authenticated', 'authenticated'), (:'par2', '923005550002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'par1' where id = :'g1'::uuid;
update public.guardian set auth_user_id = :'par2' where id = :'g2'::uuid;
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics 9') returning id as title_id \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) select :'tenant_id', :'campus_id', :'title_id', 'ACC-' || n, 'BC' || n from generate_series(1, 14) n;
select gr_number as gr_a from public.student where id = :'kid_a'::uuid \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── a plain issue ─────────────────────────────────────────────────────────
select public.issue_copy('BC1', :'kid_a'::uuid) as r1 \gset
select ok((:'r1'::jsonb ->> 'loan_id') is not null, 'a student is issued a copy');
select is((select status::text from public.library_copy where barcode = 'BC1'), 'issued', 'the copy is marked issued');
select is((select policy_snapshot ->> 'loan_days' from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), '14', 'the resolved policy is snapshotted onto the loan (14 days)');
select is((select policy_snapshot ->> 'fine_per_day' from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), '500', 'including the fine rate in paisa');
select ok((select due_on >= app.fn_karachi_today() + 14 and extract(isodow from due_on) <> 7 from public.library_loan where id = (:'r1'::jsonb ->> 'loan_id')::uuid), 'the due date is 14 days out and never a Sunday');

-- ── AC1: a second scan of the same barcode ────────────────────────────────
select throws_ok(format($$ select public.issue_copy('BC1', %L) $$, :'kid_b'), 'COPY_NOT_AVAILABLE', 'AC1: the second terminal''s scan is refused with COPY_NOT_AVAILABLE');
select is((select count(*) from public.library_loan where copy_id = (select id from public.library_copy where barcode = 'BC1') and returned_at is null), 1::bigint, 'AC1: exactly one open loan exists');
reset role;
select throws_ok(format($$ insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, due_on, policy_snapshot) select %L, %L, id, %L, 'student', current_date, '{}' from public.library_copy where barcode = 'BC1' $$, :'tenant_id', :'campus_id', :'kid_b'), '23505', null, 'AC1: the partial unique index also rejects a second open loan on the copy');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── FR-O02 AC3: copies that are not on the shelf cannot be issued ─────────
select public.set_library_copy_status(id, 'lost') from public.library_copy where barcode = 'BC2';
select throws_ok(format($$ select public.issue_copy('BC2', %L) $$, :'kid_b'), 'COPY_NOT_AVAILABLE', 'a copy in status lost is refused with COPY_NOT_AVAILABLE');
select public.set_library_copy_status(id, 'in_repair') from public.library_copy where barcode = 'BC3';
select throws_ok(format($$ select public.issue_copy('BC3', %L) $$, :'kid_b'), 'COPY_NOT_AVAILABLE', 'and so is a copy in repair');
select throws_ok(format($$ select public.issue_copy('NO-SUCH-BARCODE', %L) $$, :'kid_b'), 'COPY_NOT_FOUND', 'an unknown barcode is reported as such');

-- ── limits ────────────────────────────────────────────────────────────────
select public.issue_copy('BC4', :'teach_uid'::uuid);
select public.issue_copy('BC5', :'teach_uid'::uuid);
select public.issue_copy('BC6', :'teach_uid'::uuid);
select public.issue_copy('BC7', :'teach_uid'::uuid);
select public.issue_copy('BC8', :'teach_uid'::uuid);
select public.issue_copy('BC9', :'teach_uid'::uuid);
select throws_ok(format($$ select public.issue_copy('BC10', %L) $$, :'teach_uid'), 'LIMIT_EXCEEDED', 'a teacher holding 6 books cannot borrow a 7th');
select is(pg_temp.err_detail(format($$ select public.issue_copy('BC10', %L) $$, :'teach_uid')), '6 of 6', 'the refusal says 6 of 6');
select is((select due_on - app.fn_karachi_today() >= 30 from public.library_loan where borrower_id = :'teach_uid'::uuid order by issued_at limit 1), true, 'a teacher''s loan is 30 days');
select public.issue_copy('BC10', :'kid_a'::uuid);
select is(pg_temp.err_detail(format($$ select public.issue_copy('BC11', %L) $$, :'kid_a')), '2 of 2', 'a student at 2 of 2 is refused the third book');

-- ── AC2: blocked borrowers ────────────────────────────────────────────────
reset role;
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, issued_at, due_on, policy_snapshot, returned_at)
select :'tenant_id', :'campus_id', id, :'kid_b', 'student', now() - interval '60 days', current_date - 40, '{}', now() - interval '20 days' from public.library_copy where barcode = 'BC12' returning id as old_loan \gset
insert into public.library_fine (tenant_id, campus_id, loan_id, borrower_id, accrual_date, days_overdue, amount)
values (:'tenant_id', :'campus_id', :'old_loan', :'kid_b', current_date - 20, 7, 35000);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_copy('BC11', %L) $$, :'kid_b'), 'BORROWER_BLOCKED', 'AC2: PKR 350 of fines against a PKR 300 threshold blocks issue');
select is(pg_temp.err_detail(format($$ select public.issue_copy('BC11', %L) $$, :'kid_b')), '35000', 'AC2: and the outstanding amount (in paisa) is returned with the refusal');
select is((select outstanding_paisa from public.find_library_borrowers('Kid B') limit 1), 35000::bigint, 'AC2: the counter lookup shows the outstanding amount');

-- ── AC3: due date rolls forward past a gazetted holiday ───────────────────
reset role;
insert into public.campus_event (tenant_id, campus_id, title, event_type, starts_at, ends_at)
values (:'tenant_id', :'campus_id', 'Gazetted holiday', 'holiday', ((app.fn_karachi_today() + 14)::text || ' 12:00+05')::timestamptz, ((app.fn_karachi_today() + 15)::text || ' 12:00+05')::timestamptz);
select min(d)::date as expect_due from generate_series((app.fn_karachi_today() + 14)::timestamp, (app.fn_karachi_today() + 40)::timestamp, interval '1 day') d
 where extract(isodow from d) <> 7 and d::date not in (app.fn_karachi_today() + 14, app.fn_karachi_today() + 15) \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_copy('BC11', :'kid_c'::uuid) as r_c \gset
select is((select due_on from public.library_loan where id = (:'r_c'::jsonb ->> 'loan_id')::uuid), :'expect_due'::date, 'AC3: a due date on a holiday rolls forward to the next working day');

-- ── AC4: speed ────────────────────────────────────────────────────────────
select ok(pg_temp.elapsed_ms(format($$ select public.issue_copy('BC14', %L) $$, :'kid_c')) < 400, 'AC4: a scan is confirmed in under 400 ms');

-- ── other borrowers, other roles ──────────────────────────────────────────
select throws_ok(format($$ select public.issue_copy('BC13', %L) $$, gen_random_uuid()), 'BORROWER_NOT_FOUND', 'an unknown borrower card is refused');
select throws_ok(format($$ select public.issue_copy('BC13', %L) $$, :'prin_uid'), 'NO_POLICY', 'a borrower with no applicable policy cannot borrow');
select is((select count(*) from public.find_library_borrowers(:'gr_a')), 1::bigint, 'a GR number finds exactly that student');

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_copy('BC13', %L) $$, :'kid_b'), 'FORBIDDEN', 'a teacher cannot run the counter');
select is((select count(*) from public.library_loan), 6::bigint, 'a borrowing teacher reads only their own loans');

select set_config('request.jwt.claims', json_build_object('sub', :'par1', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.library_loan), 2::bigint, 'a parent sees their own child''s loans');
select set_config('request.jwt.claims', json_build_object('sub', :'par2', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.library_loan where borrower_id = :'kid_a'::uuid), 0::bigint, 'and not another child''s');
select is((select count(*) from public.library_fine), 1::bigint, 'a parent sees their own child''s fines');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_loan), 0::bigint, 'another school sees no loans');

select * from finish();
rollback;
