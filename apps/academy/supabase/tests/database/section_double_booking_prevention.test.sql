-- pgTAP tests for FR-F07 (section double-booking prevention / elective
-- parallel blocks).
begin;
select plan(19);

select public.provision_tenant('test-parallel-co', 'Parallel Co', 'owner@parallelco.test');
select id as tenant_id from public.tenant where slug = 'test-parallel-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@parallelco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as cs_teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'cs_teacher_id', 'cs@parallelco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'cs_teacher_id', :'tenant_id', 'subject_teacher', 'CS Teacher');

select gen_random_uuid() as bio_teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bio_teacher_id', 'bio@parallelco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bio_teacher_id', :'tenant_id', 'subject_teacher', 'Bio Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

select public.create_subject('MATH', 'Maths', 'ریاضی') as maths_id \gset
select public.create_subject('CS', 'Computer Science', 'کمپیوٹر سائنس') as cs_id \gset
select public.create_subject('BIO', 'Biology', 'حیاتیات') as bio_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'maths_id'::uuid, 1::smallint);
select public.create_room(:'campus_id'::uuid, 'R1', 'Room 1', 'CLASSROOM'::public.room_type_enum, 30) as room1_id \gset
select public.create_room(:'campus_id'::uuid, 'R2', 'Room 2', 'CLASSROOM'::public.room_type_enum, 30) as room2_id \gset

-- CS and Biology form elective bucket 1, choose_n = 1.
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'cs_id'::uuid, 1::smallint, null::uuid, false, 1::smallint, 1::smallint) as cs_class_subject_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'bio_id'::uuid, 1::smallint, null::uuid, false, 1::smallint, 1::smallint) as bio_class_subject_id \gset

select public.create_staff_teachable_subject(:'cs_teacher_id'::uuid, :'cs_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'bio_teacher_id'::uuid, :'bio_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'cs_teacher_id'::uuid, :'maths_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:40')
  ),
  true
);

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft v1') as version_id \gset

-- ── a plain, ordinary period works exactly as every prior FR established ──

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 1::smallint, :'maths_id'::uuid, :'cs_teacher_id'::uuid) as maths_slot_id \gset
select ok(:'maths_slot_id' is not null, 'a plain, non-elective slot saves exactly as it always has');

-- ── AC2: a genuine parallel block — two electives, independent teachers/rooms ──

select public.create_timetable_parallel_group(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 2::smallint, 1::smallint) as group_id \gset
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 2::smallint, :'cs_id'::uuid, :'cs_teacher_id'::uuid, :'room1_id'::uuid, 1::smallint, :'group_id'::uuid) as cs_slot_id \gset
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 2::smallint, :'bio_id'::uuid, :'bio_teacher_id'::uuid, :'room2_id'::uuid, 1::smallint, :'group_id'::uuid) as bio_slot_id \gset

select is(
  (select count(*)::int from public.timetable_slot where parallel_group_id = :'group_id'),
  2,
  'AC2: both electives save as independent rows under the one parallel group'
);
select isnt(
  (select staff_id from public.timetable_slot where id = :'cs_slot_id'),
  (select staff_id from public.timetable_slot where id = :'bio_slot_id'),
  'AC2: each member keeps its own, independent teacher'
);
select isnt(
  (select room_id from public.timetable_slot where id = :'cs_slot_id'),
  (select room_id from public.timetable_slot where id = :'bio_slot_id'),
  'AC2: each member keeps its own, independent room'
);

-- Re-saving the SAME elective (a room change) updates in place, never
-- duplicates.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 2::smallint, :'cs_id'::uuid, :'cs_teacher_id'::uuid, :'room2_id'::uuid, 1::smallint, :'group_id'::uuid) as cs_slot_again_id \gset
select is(:'cs_slot_again_id'::uuid, :'cs_slot_id'::uuid, 're-saving the same elective member reuses its own row, never duplicates');
select is(
  (select count(*)::int from public.timetable_slot where parallel_group_id = :'group_id'),
  2,
  'still exactly two rows in the group after the re-save'
);

-- ── AC1: a plain write is rejected outright once this cell is a parallel block ──

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 2::smallint, %L, %L) $$,
    :'version_id', :'section_id', :'maths_id', :'cs_teacher_id'
  ),
  'SECTION_CLASH',
  'AC1: a plain (non-elective) write to a cell already committed to a parallel block is rejected'
);

-- ── AC4: a parallel write with no elective bucket is rejected ──────────

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 3::smallint, %L, %L, null::uuid, null::smallint, %L) $$,
    :'version_id', :'section_id', :'cs_id', :'cs_teacher_id', :'group_id'
  ),
  'PARALLEL_BLOCK_REQUIRES_BUCKET',
  'AC4: joining a parallel group with no elective bucket is rejected'
);

-- ── AC5: a parallel write at a period that doesn''t match the group''s own ──

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 3::smallint, %L, %L, null::uuid, 1::smallint, %L) $$,
    :'version_id', :'section_id', :'cs_id', :'cs_teacher_id', :'group_id'
  ),
  'PARALLEL_BLOCK_PERIOD_MISMATCH',
  'AC5: a parallel group''s members must all sit in the SAME period the group itself was created for'
);

-- ── bucket consistency and curriculum membership ────────────────────────

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 2::smallint, %L, %L, null::uuid, 2::smallint, %L) $$,
    :'version_id', :'section_id', :'cs_id', :'cs_teacher_id', :'group_id'
  ),
  'PARALLEL_BLOCK_BUCKET_MISMATCH',
  'a member''s own elective_bucket must match the group''s own recorded bucket'
);
select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 2::smallint, %L, %L, null::uuid, 1::smallint, %L) $$,
    :'version_id', :'section_id', :'maths_id', :'cs_teacher_id', :'group_id'
  ),
  'SUBJECT_NOT_IN_BUCKET',
  'a subject that isn''t actually part of that elective bucket in the curriculum is rejected'
);

-- ── AC3: a student''s personal timetable shows only their own elective ──

select public.create_student(:'campus_id'::uuid, 'Elective Kid', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset
select public.set_student_elective_choice(:'student_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 1::smallint, :'bio_id'::uuid) as choice_id \gset

select public.publish_timetable(:'version_id'::uuid, '2026-01-01'::date) as published_version_id \gset

-- 2026-08-03 is used purely as a stand-in calendar date whose own weekday
-- happens to be relevant only insofar as student_timetable() resolves it
-- from the date — the actual slots above were seeded against weekday 1,
-- so the lookup date must resolve to that same weekday.
select (date '2026-08-03' + ((1 - extract(dow from date '2026-08-03')::int + 7) % 7)) as lookup_date \gset

select is(
  jsonb_array_length(public.student_timetable(:'enrolment_id'::uuid, :'lookup_date'::date)),
  2,
  'AC3: the student''s personal timetable shows exactly 2 periods — Maths, and their own chosen elective'
);
select ok(
  public.student_timetable(:'enrolment_id'::uuid, :'lookup_date'::date) @> '[{"subject_code": "BIO"}]'::jsonb,
  'AC3: Biology (their own choice) appears'
);
select ok(
  not (public.student_timetable(:'enrolment_id'::uuid, :'lookup_date'::date) @> '[{"subject_code": "CS"}]'::jsonb),
  'AC3: Computer Science (the OTHER elective in the same block) does not appear'
);

-- ── clone_timetable_version() remaps parallel groups, never orphans them ──

select public.clone_timetable_version(:'published_version_id'::uuid) as cloned_version_id \gset
select (select parallel_group_id from public.timetable_slot where timetable_version_id = :'cloned_version_id' and subject_id = :'cs_id') as cloned_group_id \gset
select isnt(
  :'cloned_group_id'::uuid, :'group_id'::uuid,
  'the clone gets its OWN parallel group row, never a reference back to the source version''s'
);
select is(
  (select timetable_version_id from public.timetable_parallel_group where id = :'cloned_group_id'),
  :'cloned_version_id'::uuid,
  'the cloned group''s own timetable_version_id actually points at the new version'
);
-- Proves the remap is self-consistent: editing the cloned CS slot (same
-- weekday/period/bucket as the cloned group''s own row) does not raise
-- PARALLEL_BLOCK_PERIOD_MISMATCH. No teacher is passed here deliberately
-- — cs_teacher_id already teaches this exact clock time in the SOURCE
-- (published) version, and the teacher-clash check (correctly) scans
-- across every version, not just the one being written; that cross-
-- version interaction is a separate, already-documented limitation
-- (see FR-F10's own migration header) this assertion isn''t testing.
select ok(
  public.upsert_timetable_slot(:'cloned_version_id'::uuid, :'section_id'::uuid, 1::smallint, 2::smallint, :'cs_id'::uuid, null::uuid, :'room1_id'::uuid, 1::smallint, :'cloned_group_id'::uuid) is not null,
  'a cloned parallel member can still be edited without a period mismatch — the remap holds together'
);

-- ── authorization ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'cs_teacher_id')::text,
  true
);
select throws_ok(
  format($$ select public.create_timetable_parallel_group(%L, %L, 1::smallint, 4::smallint, 1::smallint) $$, :'version_id', :'section_id'),
  'FORBIDDEN',
  'a subject teacher cannot create a parallel group'
);
select throws_ok(
  format($$ select public.set_student_elective_choice(%L, %L, %L, 1::smallint, %L) $$, :'student_id', :'session_id', :'class1_id', :'cs_id'),
  'FORBIDDEN',
  'a subject teacher cannot set a student''s elective choice'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select * from finish();
rollback;
