-- pgTAP tests for FR-G13 (unmarked register escalation to Principal).
begin;
select plan(13);

select public.provision_tenant('test-unmarked-co', 'Unmarked Co', 'owner@unmarkedco.test');
select id as tenant_id from public.tenant where slug = 'test-unmarked-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@unmarkedco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. B Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'C', 40) as section_c \gset
select public.assign_class_teacher(:'section_b'::uuid, :'teacher_user_id'::uuid, current_date - 100);

-- Section A: 2 students, fully marked. Section B: 3 students, only 1
-- marked (partial). Section C: 2 students, none marked at all.
select public.create_student(:'campus_id'::uuid, 'A1', '2015-01-01'::date, 'male') as a1 \gset
select public.enrol_student(:'section_a'::uuid, :'a1'::uuid) as a1_enrol \gset
select public.create_student(:'campus_id'::uuid, 'A2', '2015-01-01'::date, 'female') as a2 \gset
select public.enrol_student(:'section_a'::uuid, :'a2'::uuid) as a2_enrol \gset

select public.create_student(:'campus_id'::uuid, 'B1', '2015-01-01'::date, 'male') as b1 \gset
select public.enrol_student(:'section_b'::uuid, :'b1'::uuid) as b1_enrol \gset
select public.create_student(:'campus_id'::uuid, 'B2', '2015-01-01'::date, 'female') as b2 \gset
select public.enrol_student(:'section_b'::uuid, :'b2'::uuid) as b2_enrol \gset
select public.create_student(:'campus_id'::uuid, 'B3', '2015-01-01'::date, 'male') as b3 \gset
select public.enrol_student(:'section_b'::uuid, :'b3'::uuid) as b3_enrol \gset

select public.create_student(:'campus_id'::uuid, 'C1', '2015-01-01'::date, 'male') as c1 \gset
select public.enrol_student(:'section_c'::uuid, :'c1'::uuid) as c1_enrol \gset
select public.create_student(:'campus_id'::uuid, 'C2', '2015-01-01'::date, 'female') as c2 \gset
select public.enrol_student(:'section_c'::uuid, :'c2'::uuid) as c2_enrol \gset

-- enrol_student() always sets joined_on = current_date with no override
-- parameter, so the check date has to be today for the enrolled_count
-- subquery to see these students as active on that date.
select current_date as check_date \gset

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'a1_enrol'::uuid, :'check_date'::date, 'present', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'a2_enrol'::uuid, :'check_date'::date, 'present', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_b'::uuid, :'b1_enrol'::uuid, :'check_date'::date, 'present', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── the underlying finder, called directly ─────────────────────────────

select is(
  (select count(*)::int from public.check_unmarked_attendance(:'campus_id'::uuid, :'check_date'::date)),
  2,
  'check_unmarked_attendance() finds exactly sections B and C — A is fully marked and excluded'
);
select is(
  (select marked_count from public.check_unmarked_attendance(:'campus_id'::uuid, :'check_date'::date) where section_id = :'section_b'::uuid),
  1,
  'section B reports marked_count = 1'
);
select is(
  (select class_teacher_name from public.check_unmarked_attendance(:'campus_id'::uuid, :'check_date'::date) where section_id = :'section_b'::uuid),
  'Ms. B Teacher',
  'section B resolves its own assigned class teacher''s name'
);
select is(
  (select class_teacher_name from public.check_unmarked_attendance(:'campus_id'::uuid, :'check_date'::date) where section_id = :'section_c'::uuid),
  'Unassigned',
  'section C, with no class teacher assigned, falls back to "Unassigned"'
);

-- ── AC1/AC4: the digest lists exactly B and C, correctly distinguishing
--    "partially marked" from fully "unmarked" ─────────────────────────

select public.run_unmarked_attendance_check(:'campus_id'::uuid, :'check_date'::date) as digest \gset
select is(
  jsonb_array_length(:'digest'::jsonb -> 'sections'),
  2,
  'AC1: the digest lists exactly 2 sections'
);
select ok(
  exists (select 1 from jsonb_array_elements(:'digest'::jsonb -> 'sections') s where s ->> 'section_id' = :'section_b' and s ->> 'status' = 'partially marked (1/3)'),
  'AC4: section B is reported as "partially marked (1/3)", not lumped in as plain "unmarked"'
);
select ok(
  exists (select 1 from jsonb_array_elements(:'digest'::jsonb -> 'sections') s where s ->> 'section_id' = :'section_c' and s ->> 'status' = 'unmarked'),
  'AC4: section C, with zero rows at all, is reported as "unmarked"'
);
select ok(
  not exists (select 1 from jsonb_array_elements(:'digest'::jsonb -> 'sections') s where s ->> 'section_id' = :'section_a'),
  'section A (fully marked) never appears in the digest'
);

-- ── AC3: re-running the check for the SAME date never re-flags a
--    section that was already logged, even though it is still unmarked ─

select public.run_unmarked_attendance_check(:'campus_id'::uuid, :'check_date'::date) as digest2 \gset
select is(
  jsonb_array_length(:'digest2'::jsonb -> 'sections'),
  0,
  'AC3: a second run for the same date returns no sections — both were already logged'
);
select is(
  (select count(*)::int from public.attendance_gap_log where campus_id = :'campus_id'::uuid and attendance_date = :'check_date'::date),
  2,
  'exactly 2 gap_log rows exist for that date, not 4 — the re-run inserted nothing new'
);

-- ── AC2: a declared holiday skips the check entirely ───────────────────

select (current_date + 1) as holiday_date \gset
select public.add_holiday(:'holiday_date'::date, 'Founder''s Day', :'campus_id'::uuid);
select public.run_unmarked_attendance_check(:'campus_id'::uuid, :'holiday_date'::date) as holiday_digest \gset
select is(
  (:'holiday_digest'::jsonb ->> 'skipped')::boolean,
  true,
  'AC2: a declared holiday skips the check entirely'
);
select is(
  jsonb_array_length(:'holiday_digest'::jsonb -> 'sections'),
  0,
  'AC2: a skipped (holiday) run reports zero sections, not the actual unmarked count'
);

-- ── validation ──────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format('select public.run_unmarked_attendance_check(%L, %L)', :'campus_id', :'check_date'),
  'FORBIDDEN',
  'a subject teacher cannot trigger the unmarked-attendance check'
);

select * from finish();
rollback;
