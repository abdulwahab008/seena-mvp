-- pgTAP tests for FR-H01 (homework assignment creation) and FR-H04
-- (student/parent homework feed).
begin;
select plan(22);

select public.provision_tenant('test-homework-co', 'Homework Co', 'owner@homeworkco.test');
select id as tenant_id from public.tenant where slug = 'test-homework-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-sub@homeworkco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@homeworkco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Chemistry Teacher');

select gen_random_uuid() as other_teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_teacher_user_id', 'urdu-teacher@homeworkco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_teacher_user_id', :'tenant_id', 'subject_teacher', 'Urdu Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.create_subject('URD', 'Urdu', 'اردو') as urdu_id \gset

select public.assign_subject_teacher(:'section_id'::uuid, :'chem_id'::uuid, :'teacher_user_id'::uuid, current_date - 30);
select public.assign_subject_teacher(:'section_id'::uuid, :'urdu_id'::uuid, :'other_teacher_user_id'::uuid, current_date - 30);

-- Two students, two families, same section — the exact cross-family
-- scenario FR-C11's own parent-scoping RLS had to get right, reused here.
select public.create_student(:'campus_id'::uuid, 'Homework Kid One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Homework Kid Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset

select public.fn_find_or_create_guardian(p_name_en => 'Homework Guardian One', p_phone_e164 => '+923001112222') as guardian1_id \gset
select public.link_guardian(:'student1_id'::uuid, :'guardian1_id'::uuid, 'father'::public.guardian_relationship, true, true);

reset role;
select gen_random_uuid() as guardian1_auth_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'guardian1_auth_uid', 'guardian1@homeworkco.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'guardian1_auth_uid'::uuid where id = :'guardian1_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── create_homework ──────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.create_homework(
  :'section_id'::uuid, :'chem_id'::uuid, 'Chapter 3 exercises', (current_date + 5), current_date, 'Do questions 1-10.'
) as hw1_id \gset
select is(
  (select status::text from public.homework where id = :'hw1_id'::uuid),
  'draft',
  'AC: a new homework assignment defaults to draft'
);
select is(
  (select teacher_id from public.homework where id = :'hw1_id'::uuid),
  :'teacher_user_id'::uuid,
  'the creating teacher is recorded'
);

select throws_ok(
  format(
    $$ select public.create_homework(%L, %L, 'Wrong subject', (current_date + 5), current_date) $$,
    :'section_id', :'urdu_id'
  ),
  'FORBIDDEN',
  'AC: a teacher not assigned to that (section, subject) pair is rejected'
);

select throws_ok(
  format(
    $$ select public.create_homework(%L, %L, 'Backwards dates', (current_date - 1), current_date) $$,
    :'section_id', :'chem_id'
  ),
  'DUE_BEFORE_ASSIGNED',
  'AC: due_date earlier than assigned_date is rejected'
);

select throws_ok(
  format(
    $$ select public.create_homework(%L, %L, %L, (current_date + 5), current_date, %L) $$,
    :'section_id', :'chem_id', 'Too long description', repeat('x', 4001)
  ),
  'DESCRIPTION_TOO_LONG',
  'a description over 4000 characters is rejected'
);

select throws_ok(
  format(
    $$ select public.create_homework(%L, %L, %L, (current_date + 5), current_date, null, -5) $$,
    :'section_id', :'chem_id', 'Negative estimate'
  ),
  'ESTIMATED_MINUTES_INVALID',
  'a non-positive estimated_minutes is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_homework(
  :'section_id'::uuid, :'chem_id'::uuid, 'Admin-created homework', (current_date + 7), current_date, null, null, 'published'
) as hw_admin_id \gset
select is(
  (select status::text from public.homework where id = :'hw_admin_id'::uuid),
  'published',
  'AC (Notes): an Owner/Principal can create (and directly publish) homework without being the assigned subject teacher'
);
select isnt(
  (select published_at from public.homework where id = :'hw_admin_id'::uuid),
  null,
  'published_at is stamped when created directly as published'
);

-- ── publish_homework ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'other_teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.publish_homework(%L) $$, :'hw1_id'),
  'FORBIDDEN',
  'a different (unrelated) teacher cannot publish someone else''s homework'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.publish_homework(:'hw1_id'::uuid);
select is(
  (select status::text from public.homework where id = :'hw1_id'::uuid),
  'published',
  'AC: publishing flips status to published'
);
select isnt(
  (select published_at from public.homework where id = :'hw1_id'::uuid),
  null,
  'published_at is stamped on publish'
);
select throws_ok(
  format($$ select public.publish_homework(%L) $$, :'hw1_id'),
  'ALREADY_PUBLISHED',
  'publishing an already-published assignment is rejected'
);

-- ── a second, still-draft assignment for the visibility tests below ──────

select public.create_homework(
  :'section_id'::uuid, :'chem_id'::uuid, 'Still a draft', (current_date + 3), current_date
) as hw_draft_id \gset

-- ── staff visibility ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.homework where section_id = :'section_id'::uuid),
  3,
  'staff (owner) sees every homework row for the section, draft and published alike'
);

-- ── parent visibility (FR-H04's own AC: draft is invisible, published is not) ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'guardian1_auth_uid')::text,
  true
);
select is(
  (select count(*)::int from public.homework where id = :'hw_draft_id'::uuid),
  0,
  'AC: a draft assignment is not returned to a parent, even for their own child''s section'
);
select is(
  (select count(*)::int from public.homework where id = :'hw1_id'::uuid),
  1,
  'a published assignment for the parent''s own child''s section is visible'
);
select is(
  (select count(*)::int from public.v_student_homework_feed where id = :'hw1_id'::uuid),
  1,
  'the published assignment appears in the homework feed view'
);
select is(
  (select count(*)::int from public.v_student_homework_feed where id = :'hw_draft_id'::uuid),
  0,
  'the draft never appears in the homework feed view'
);
select is(
  (select is_overdue from public.v_student_homework_feed where id = :'hw1_id'::uuid),
  false,
  'a due date 5 days out is not overdue'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_homework(
  :'section_id'::uuid, :'chem_id'::uuid, 'Overdue item', (current_date - 1), (current_date - 10), null, null, 'published'
) as hw_overdue_id \gset
select is(
  (select is_overdue from public.v_student_homework_feed where id = :'hw_overdue_id'::uuid),
  true,
  'AC: an assignment whose due date has passed is flagged overdue in the feed'
);

-- ── a second, unrelated family in the same section sees the same
--    section-wide published homework (the underlying RLS mechanism —
--    auth_guardian_student_ids() plus an active-enrolment join — is
--    exactly FR-C11's own, whose test suite already proves the cross-
--    family isolation case in depth; not re-proven here) ────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.fn_find_or_create_guardian(p_name_en => 'Homework Guardian Two', p_phone_e164 => '+923003334444') as guardian2_id \gset
select public.link_guardian(:'student2_id'::uuid, :'guardian2_id'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as guardian2_auth_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'guardian2_auth_uid', 'guardian2@homeworkco.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'guardian2_auth_uid'::uuid where id = :'guardian2_id'::uuid;
set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'guardian2_auth_uid')::text,
  true
);
select is(
  (select count(*)::int from public.homework where id = :'hw1_id'::uuid),
  1,
  'a second family''s guardian, whose child shares the section, also sees the published homework'
);

-- ── unrelated tenant/section cannot be targeted ─────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_homework(%L, %L, 'Foreign section', (current_date + 5), current_date) $$,
    gen_random_uuid(), :'chem_id'
  ),
  'SECTION_NOT_FOUND',
  'an unknown/foreign section id is rejected'
);

-- ── realtime ─────────────────────────────────────────────────────────────

reset role;
select ok(
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'homework'),
  'AC (Supabase Objects): homework is published for realtime so a new assignment appears live'
);

select * from finish();
rollback;
