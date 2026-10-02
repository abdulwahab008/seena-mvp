-- pgTAP tests for FR-T13: government census and EMIS return generation.
begin;
select plan(29);

select public.provision_tenant('test-census-co', 'Census Co', 'owner@census.test');
select id as tenant_id from public.tenant where slug = 'test-census-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'CB', 'Census Campus B') returning id as campus_b \gset
select public.provision_tenant('test-census-other', 'Other Census Co', 'owner@othercensus.test');
select id as other_tenant_id from public.tenant where slug = 'test-census-other' \gset
select id as c1 from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as c2 from public.class_level where tenant_id = :'tenant_id' and code = '2' \gset
select id as c3 from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset

-- 3 classes x 3 sections of 200
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', :'campus_a', :'session_id', cl, 'S' || n, 200 from (values (:'c1'::uuid), (:'c2'::uuid), (:'c3'::uuid)) c(cl), generate_series(1, 3) n;

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_a_uid \gset
select gen_random_uuid() as prin_b_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@census.test', 'authenticated', 'authenticated', 'x'), (:'prin_a_uid', 'pa@census.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_b_uid', 'pb@census.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@census.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Census Owner'), (:'prin_a_uid', :'tenant_id', 'principal', 'Principal A'), (:'prin_b_uid', :'tenant_id', 'principal', 'Principal B'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_a_uid', :'tenant_id', :'campus_a'), (:'prin_b_uid', :'tenant_id', :'campus_b'), (:'teach_uid', :'tenant_id', :'campus_a');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
-- 1,238 regular students, all enrolled since April 2025 and never left, spread over classes, sections and genders
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'CE' || lpad(g::text, 5, '0'), 'Census Kid ' || g, date '2013-01-15' + (g % 700), (array['male', 'female', 'other'])[1 + g % 3]::public.gender from generate_series(1, 1238) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, joined_on)
select s.tenant_id, s.campus_id, :'session_id', s.id, sec.class_level_id, sec.id, date '2025-04-01'
  from (select st.*, row_number() over (order by gr_number) as n from public.student st where st.tenant_id = :'tenant_id') s
  join (select *, row_number() over (order by class_level_id, name) as k from public.class_section where tenant_id = :'tenant_id') sec on sec.k = 1 + (s.n % 9);

-- the special cases of the acceptance criteria, census date 2026-03-01
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender) values
  (:'tenant_id', :'campus_a', 'CX-TRANSFER', 'Transferred in April', '2013-05-05', 'male'),
  (:'tenant_id', :'campus_a', 'CX-LATE', 'Admitted 15 March', '2013-05-05', 'female'),
  (:'tenant_id', :'campus_a', 'CX-JOINDAY', 'Joined on census day', '2013-05-05', 'female'),
  (:'tenant_id', :'campus_a', 'CX-LEFTDAY', 'Left on census day', '2013-05-05', 'male'),
  (:'tenant_id', :'campus_a', 'CX-DELETED', 'Soft deleted', '2013-05-05', 'male'),
  (:'tenant_id', :'campus_a', 'CX-NODOB', 'Bad birth date', '2026-06-01', 'male');
select id as sec_s1 from public.class_section where tenant_id = :'tenant_id' and name = 'S1' and class_level_id = :'c1' \gset
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, joined_on, left_on, status)
select :'tenant_id', :'campus_a', :'session_id', id, :'c1', :'sec_s1',
       case gr_number when 'CX-LATE' then date '2026-03-15' when 'CX-JOINDAY' then date '2026-03-01' else date '2025-04-01' end,
       case gr_number when 'CX-TRANSFER' then date '2026-04-10' when 'CX-LEFTDAY' then date '2026-03-01' end,
       case gr_number when 'CX-TRANSFER' then 'transferred'::public.enrolment_status when 'CX-LEFTDAY' then 'left'::public.enrolment_status else 'active'::public.enrolment_status end
  from public.student where tenant_id = :'tenant_id' and gr_number like 'CX-%' and gr_number <> 'CX-NODOB';
update public.enrolment set deleted_at = now() where student_id = (select id from public.student where gr_number = 'CX-DELETED' and tenant_id = :'tenant_id');
-- the bad-birth-date student is a regular member of the roll, counted but with unknown age
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, joined_on)
select :'tenant_id', :'campus_a', :'session_id', id, :'c1', :'sec_s1', date '2025-04-01' from public.student where tenant_id = :'tenant_id' and gr_number = 'CX-NODOB';
-- bring the roll to exactly 1,240 on 2026-03-01: 1,238 regular + transferred + join-day, plus the bad-dob student = 1,241; drop one regular
delete from public.enrolment where student_id = (select id from public.student where tenant_id = :'tenant_id' and gr_number = 'CE00001');

select has_index('public', 'enrolment', 'idx_enrolment_asof', 'idx_enrolment_asof exists');
select is((select count(*)::int from public.census_framework_spec), 5, 'the five frameworks are configured');

-- ── enrolment_as_of boundaries ────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-03-01'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-TRANSFER'), 1, 'AC1: the student who transferred out on 2026-04-10 IS on the 2026-03-01 roll');
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-03-01'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-LATE'), 0, 'AC2: the student admitted 2026-03-15 is NOT');
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-03-01'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-JOINDAY'), 1, 'joined on the census date: counted');
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-03-01'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-LEFTDAY'), 0, 'left on the census date: not counted');
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-03-01'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-DELETED'), 0, 'a soft-deleted enrolment is not counted');
select is((select count(*)::int from public.enrolment_as_of(:'campus_a'::uuid, '2026-04-11'::date) e join public.student s on s.id = e.student_id where s.gr_number = 'CX-TRANSFER'), 0, 'but after the transfer date they are gone');
select is((select prosecdef from pg_proc where oid = 'public.enrolment_as_of(uuid,date)'::regprocedure), false, 'enrolment_as_of is SECURITY INVOKER: the caller''s campus RLS applies');

-- ── generation (the return is generated "today", for a date in March) ────
select public.generate_census_return(:'campus_a'::uuid, 'punjab_emis', '2026-03-01'::date) as run1 \gset
select is((select status from public.census_return_run where id = :'run1'), 'done', 'the run completes');
select is((select total_students from public.census_return_run where id = :'run1'), 1240, 'AC1/AC2: the roll on 2026-03-01 is exactly 1,240');
select is((select sum(value)::int from public.census_cell where run_id = :'run1' and metric = 'enrolment'), 1240, 'AC3: the class-by-gender cells sum to 1,240 exactly');
select is((select sum(value)::int from public.census_cell where run_id = :'run1' and metric = 'enrolment_by_age'), 1240, 'and so do the class-by-age cells');
select is((select reconciliation_ok from public.census_return_run where id = :'run1'), true, 'AC3: reconciliation passed');
select is((select count(*)::int from public.census_cell where run_id = :'run1' and metric = 'enrolment' and dimension_key ->> 'class_code' = '1' and dimension_key ->> 'gender' = 'male'), 1, 'cells carry class and gender dimensions');

-- ── AC4: unknown age is bucketed and flagged, never dropped ───────────────
select is((select value from public.census_cell where run_id = :'run1' and metric = 'enrolment_by_age' and dimension_key = '{"class_code":"1","age":"unknown"}'), 1, 'AC4: the student with no usable birth date is in the "unknown" age bucket');
select is((select incomplete from public.census_return_run where id = :'run1'), true, 'AC4: the run is flagged incomplete');
select is((select unknown_age_count from public.census_return_run where id = :'run1'), 1, 'AC4: with the count of such students');
select is(app.fn_census_age(null, '2026-03-01'), 'unknown', 'a missing date of birth is "unknown"');
select is(app.fn_census_age('2014-03-01', '2026-03-01'), '12', 'age is completed years on the census date');

-- ── AC5: regenerating reproduces the return ───────────────────────────────
select public.generate_census_return(:'campus_a'::uuid, 'punjab_emis', '2026-03-01'::date) as run2 \gset
select isnt(:'run2'::text, :'run1'::text, 'regenerating makes a new run');
select is((select cells_digest from public.census_return_run where id = :'run2'), (select cells_digest from public.census_return_run where id = :'run1'), 'AC5: with identical cells (same digest)');

-- ── the reconciliation assertion ──────────────────────────────────────────
reset role;
update public.census_cell set value = value + 1 where run_id = :'run2' and metric = 'enrolment' and dimension_key = '{"class_code":"1","gender":"male"}';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is(public.verify_census_run(:'run2'::uuid), false, 'a tampered cell fails the reconciliation');
select is((select status from public.census_return_run where id = :'run2'), 'failed', 'and the run is marked failed, not done');

-- ── access ────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_b_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select public.generate_census_return(%L, 'punjab_emis', '2026-03-01') $$, :'campus_a'), 'CAMPUS_NOT_FOUND', 'a Principal cannot generate another campus''s return');
select is((select count(*)::int from public.census_return_run), 0, 'nor read it');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.generate_census_return(%L, 'punjab_emis', '2026-03-01') $$, :'campus_a'), 'FORBIDDEN', 'a teacher cannot generate a return');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_a_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.generate_census_return(%L, 'martian_emis', '2026-03-01') $$, :'campus_a'), 'FRAMEWORK_UNKNOWN', 'an unknown framework is refused');
select throws_ok(format($$ select public.generate_census_return(%L, 'federal', current_date + 30) $$, :'campus_a'), 'CENSUS_DATE_INVALID', 'a census date in the future is refused');
reset role;

select * from finish();
rollback;
