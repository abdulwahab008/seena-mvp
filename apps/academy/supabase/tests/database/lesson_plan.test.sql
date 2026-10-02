-- pgTAP tests for FR-H10: lesson plan creation against syllabus units.
begin;
select plan(21);

select public.provision_tenant('test-lesson-co', 'Lesson Co', 'owner@lesson.test');
select id as tenant_id from public.tenant where slug = 'test-lesson-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-lesson-other', 'Other Lesson Co', 'owner@otherlesson.test');
select id as other_tenant_id from public.tenant where slug = 'test-lesson-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as teach2_uid \gset
select gen_random_uuid() as prin_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@lesson.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@lesson.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@lesson.test', 'authenticated', 'authenticated', 'x'), (:'teach2_uid', 't2@lesson.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@lesson.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher'),
  (:'teach2_uid', :'tenant_id', 'subject_teacher', 'Maths Teacher'), (:'prin_uid', :'tenant_id', 'principal', 'Principal');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات'), (:'tenant_id', 'MTH', 'Maths', 'ریاضی');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
select id as mth from public.subject where tenant_id = :'tenant_id' and code = 'MTH' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
reset role;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'teach_uid', current_date - 60),
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'mth', :'teach2_uid', current_date - 60);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  '[{"title":"Motion","topics":[{"title":"Speed"},{"title":"Velocity"}]},{"title":"Force","topics":[{"title":"Newton one"}]}]'::jsonb);
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'mth'::uuid, 'FBISE'::public.board,
  '[{"title":"Algebra","topics":[{"title":"Equations"}]}]'::jsonb);
select id as t_speed from public.syllabus_topic where title = 'Speed' and tenant_id = :'tenant_id' \gset
select id as t_velocity from public.syllabus_topic where title = 'Velocity' and tenant_id = :'tenant_id' \gset
select id as t_newton from public.syllabus_topic where title = 'Newton one' and tenant_id = :'tenant_id' \gset
select id as t_eq from public.syllabus_topic where title = 'Equations' and tenant_id = :'tenant_id' \gset

-- ── AC4: any date becomes the Monday of its ISO week ──────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_lesson_plan(:'sec'::uuid, :'phy'::uuid, '2026-09-09'::date, 'Understand speed and velocity', 'Worksheet 3', array[:'t_speed', :'t_velocity']::uuid[]) as plan1 \gset
select is((select week_start_date from public.lesson_plan where id = :'plan1'::uuid), '2026-09-07'::date, 'AC4: a Wednesday is normalised to that week''s Monday (2026-09-07)');
select is((select count(*) from public.lesson_plan_topic where lesson_plan_id = :'plan1'::uuid), 2::bigint, 'the plan links its two topics');

-- ── AC2: one plan per section, subject and week ───────────────────────────
select throws_ok(format($$ select public.create_lesson_plan(%L, %L, '2026-09-07') $$, :'sec', :'phy'), 'LESSON_PLAN_EXISTS', 'AC2: a second plan for the same week is refused');
select lives_ok(format($$ select public.create_lesson_plan(%L, %L, '2026-09-14', 'Forces', null, array[%L]::uuid[]) $$, :'sec', :'phy', :'t_newton'), 'the next week is a separate plan');

-- ── AC1: only topics of this subject's syllabus ───────────────────────────
select throws_ok(format($$ select public.create_lesson_plan(%L, %L, '2026-09-21', null, null, array[%L]::uuid[]) $$, :'sec', :'phy', :'t_eq'), 'TOPIC_NOT_IN_SYLLABUS', 'AC1: a topic from another subject''s syllabus is refused');
select throws_ok(format($$ select public.update_lesson_plan(%L, 'x', null, array[%L]::uuid[]) $$, :'plan1', :'t_eq'), 'TOPIC_NOT_IN_SYLLABUS', 'and cannot be added later either');
select throws_ok(format($$ select public.create_lesson_plan(%L, %L, '2026-09-21') $$, :'sec', :'mth'), 'FORBIDDEN', 'a teacher cannot plan a subject they are not assigned to');
select throws_ok(format($$ select public.create_lesson_plan(%L, %L, '2026-09-21', %L) $$, :'sec', :'phy', repeat('x', 1001)), 'TEXT_TOO_LONG', 'objectives are capped at 1000 characters');

-- ── editing and completing ────────────────────────────────────────────────
select public.update_lesson_plan(:'plan1'::uuid, 'Understand speed', 'Worksheet 3 and a demo', array[:'t_speed']::uuid[]);
select is((select count(*) from public.lesson_plan_topic where lesson_plan_id = :'plan1'::uuid), 1::bigint, 'editing replaces the linked topics');
select is((select objectives from public.lesson_plan where id = :'plan1'::uuid), 'Understand speed', 'and the objectives');
select public.set_lesson_plan_status(:'plan1'::uuid, 'in_progress');
select is((select status from public.lesson_plan where id = :'plan1'::uuid), 'in_progress', 'a plan can move to in progress');
select public.set_lesson_plan_status(:'plan1'::uuid, 'completed');
select is((select completion_date from public.lesson_plan where id = :'plan1'::uuid), app.fn_karachi_today(), 'AC5: completing a plan records the completion date');
select ok((select completed_at is not null from public.lesson_plan where id = :'plan1'::uuid), 'and the time');
select throws_ok(format($$ select public.set_lesson_plan_status(%L, 'done') $$, :'plan1'), 'STATUS_INVALID', 'an unknown status is refused');
select public.set_lesson_plan_status(:'plan1'::uuid, 'planned');
select is((select completed_at is null and completion_date is null from public.lesson_plan where id = :'plan1'::uuid), true, 'reopening clears the completion');

-- ── AC3: principal reads everything, read-only ────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.lesson_plan), 0::bigint, 'another teacher sees none of these plans');
select throws_ok(format($$ select public.update_lesson_plan(%L, 'hijack') $$, :'plan1'), 'FORBIDDEN', 'and cannot edit them');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.lesson_plan), 2::bigint, 'AC3: the Principal sees every plan of the campus');
select is((select count(*) from public.lesson_plan where teacher_id = :'teach_uid'::uuid and week_start_date = '2026-09-07'), 1::bigint, 'and can filter by teacher and week');
select throws_ok(format($$ select public.set_lesson_plan_status(%L, 'completed') $$, :'plan1'), 'FORBIDDEN', 'AC3: but cannot change a plan (read-only)');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.lesson_plan), 0::bigint, 'another school sees none');

select * from finish();
rollback;
