-- pgTAP tests for FR-O03: role-based borrowing limits and periods.
begin;
select plan(22);

select public.provision_tenant('test-libpol-co', 'Lib Policy Co', 'owner@libpol.test');
select id as tenant_id from public.tenant where slug = 'test-libpol-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select public.provision_tenant('test-libpol-other', 'Other Lib Policy Co', 'owner@otherlibpol.test');
select id as other_tenant_id from public.tenant where slug = 'test-libpol-other' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'JT', 'Johar Town') returning id as johar_id \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as lib_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@libpol.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@libpol.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@libpol.test', 'authenticated', 'authenticated', 'x'), (:'lib_uid', 'l@libpol.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'lib_uid', :'tenant_id', 'librarian', 'Librarian');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'teach_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '3';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class3_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Class Three Kid', '2016-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'section_id'::uuid, :'kid'::uuid);

-- ── policy as the Principal configures it ─────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_borrower_policy('student', 2, 14, 1, 500, '2026-01-01'::date, null, null, null, 50000, 30000) as stud_pol \gset
select public.set_borrower_policy('teacher', 6, 30, 3, 0, '2026-01-01'::date) as teach_pol \gset
select is((select max_loans from public.resolve_borrower_policy(:'teach_uid'::uuid, '2026-08-20 10:00+05')), 6, 'AC1: a teacher resolves to 6 loans');
select is((select loan_days from public.resolve_borrower_policy(:'teach_uid'::uuid, '2026-08-20 10:00+05')), 30, 'AC1: for 30 days');
select is((select max_renewals from public.resolve_borrower_policy(:'teach_uid'::uuid, '2026-08-20 10:00+05')), 3, 'AC1: with 3 renewals');
select is((select fine_per_day from public.resolve_borrower_policy(:'teach_uid'::uuid, '2026-08-20 10:00+05')), 0::bigint, 'AC1: and no fine');
select is((select max_loans from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-20 10:00+05')), 2, 'AC1: a student resolves to 2 loans');
select is((select fine_cap from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-20 10:00+05')), 50000::bigint, 'AC1: with a PKR 500 cap (paisa)');

-- ── AC2: the class-band row wins over the role row ────────────────────────
select public.set_borrower_policy('student', 1, 7, 0, 500, '2026-01-01'::date, null, 0::smallint, 5::smallint, 50000, 30000) as band_pol \gset
select is((select loan_days from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-20 10:00+05')), 7, 'AC2: a Class 3 student (inside the Nursery to Class 4 band) gets the band row: 7 days');
select is((select max_loans from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-20 10:00+05')), 1, 'AC2: and 1 loan');
select is((select id from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-20 10:00+05')), :'band_pol'::uuid, 'AC2: the band row is the one chosen');

-- ── AC3: a rate change is dated and never rewrites the past ───────────────
select public.set_borrower_policy('student', 1, 7, 0, 1000, '2026-08-01'::date, null, 0::smallint, 5::smallint, 50000, 30000);
select is((select fine_per_day from public.resolve_borrower_policy(:'kid'::uuid, '2026-07-25 10:00+05')), 500::bigint, 'AC3: on 2026-07-25 the fine rate is still PKR 5');
select is((select fine_per_day from public.resolve_borrower_policy(:'kid'::uuid, '2026-08-02 10:00+05')), 1000::bigint, 'AC3: from 2026-08-01 it is PKR 10');
select is((select count(*) from public.library_borrower_policy where tenant_id = :'tenant_id' and class_band_from = 0), 2::bigint, 'AC3: the old rate row is kept, not overwritten');
select public.set_borrower_policy('student', 1, 7, 0, 1200, '2026-08-01'::date, null, 0::smallint, 5::smallint, 50000, 30000);
select is((select count(*) from public.library_borrower_policy where tenant_id = :'tenant_id' and class_band_from = 0), 2::bigint, 're-saving the same slot and date updates it in place');

-- ── campus-specific beats school-wide; unknown borrower resolves to nothing ──
select public.set_borrower_policy('teacher', 4, 21, 1, 0, '2026-01-01'::date, :'campus_id'::uuid);
select is((select max_loans from public.resolve_borrower_policy(:'teach_uid'::uuid, '2026-08-20 10:00+05')), 4, 'a campus-specific row beats the school-wide row');
select is((select id from public.resolve_borrower_policy(gen_random_uuid(), now())), null, 'an unknown borrower resolves to no policy');
select throws_ok($$ select public.set_borrower_policy('teacher', 4, 21, 1, 0, '2026-01-01', null, 1::smallint, 3::smallint) $$, 'POLICY_BAND_INVALID', 'a class band only applies to students');
select throws_ok($$ select public.set_borrower_policy('student', 1, 7, 0, 500, '2026-01-01', null, 5::smallint, 2::smallint) $$, 'POLICY_BAND_INVALID', 'a reversed band is refused');

-- ── AC4: a teacher cannot edit the table ──────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ insert into public.library_borrower_policy (tenant_id, role, max_loans, loan_days, effective_from) values (%L, 'student', 99, 99, '2026-01-01') $$, :'tenant_id'), '42501', null, 'AC4: a teacher''s direct insert is refused by RLS');
update public.library_borrower_policy set max_loans = 99 where id = :'stud_pol'::uuid;
reset role;
select is((select max_loans from public.library_borrower_policy where id = :'stud_pol'::uuid), 2, 'AC4: a teacher''s update changes nothing (RLS)');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.set_borrower_policy('student', 99, 99, 9, 0, '2026-01-01') $$, 'FORBIDDEN', 'AC4: and so is the RPC');
select cmp_ok((select count(*) from public.library_borrower_policy), '>', 0::bigint, 'but the policy can be read by the campus');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_borrower_policy), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
