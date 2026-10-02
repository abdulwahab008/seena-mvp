-- pgTAP tests for FR-F11 (per-section timetable view).
begin;
select plan(15);

select public.provision_tenant('test-sectiontt-co', 'Section TT Co', 'owner@sectiontt.test');
select id as tenant_id from public.tenant where slug = 'test-sectiontt-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@sectiontt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@sectiontt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Physics Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.create_room(:'campus_id'::uuid, 'R1', 'Room 1', 'CLASSROOM'::public.room_type_enum, 30) as room_id \gset

select public.create_student(:'campus_id'::uuid, 'Section TT Kid', '2015-01-01'::date, 'male') as student_a_id \gset
select public.enrol_student(:'section_a_id'::uuid, :'student_a_id'::uuid) as enrol_a_id \gset
select public.create_student(:'campus_id'::uuid, 'Unrelated Kid', '2015-01-01'::date, 'female') as student_b_id \gset
select public.enrol_student(:'section_b_id'::uuid, :'student_b_id'::uuid) as enrol_b_id \gset

select public.fn_find_or_create_guardian(p_name_en => 'Section TT Guardian', p_phone_e164 => '+923005556666') as guardian_id \gset
select public.link_guardian(:'student_a_id'::uuid, :'guardian_id'::uuid, 'father'::public.guardian_relationship, true, true);

reset role;
select gen_random_uuid() as guardian_auth_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'guardian_auth_uid', 'guardian@sectiontt.test', 'x', now(), 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'guardian_auth_uid'::uuid where id = :'guardian_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- A Published version with a real, staffed, roomed slot in section A, and
-- an unrelated one in section B; a DRAFT version with its own slot in
-- section A, to prove drafts stay invisible to a parent.
reset role;
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'Published v1', 'PUBLISHED', 1, '2026-01-01')
returning id as published_version_id \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'Draft v2', 'DRAFT', 2)
returning id as draft_version_id \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id, room_id)
values (:'tenant_id', :'campus_id', :'published_version_id', :'section_a_id', 1, 1, :'physics_id', :'teacher_user_id', :'room_id')
returning id as published_slot_a_id \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id, room_id)
values (:'tenant_id', :'campus_id', :'published_version_id', :'section_b_id', 1, 1, :'physics_id', :'teacher_user_id', :'room_id')
returning id as published_slot_b_id \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id, room_id)
values (:'tenant_id', :'campus_id', :'draft_version_id', :'section_a_id', 1, 1, :'physics_id', :'teacher_user_id', :'room_id')
returning id as draft_slot_a_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── staff read: unrestricted by status, exactly like the write-side grid ──

select is(
  (select count(*)::int from public.v_section_timetable where section_id = :'section_a_id'),
  2,
  'staff (campus-scoped) sees both the Published and Draft slots for section A'
);
select is(
  (select teacher_name from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  'Physics Teacher',
  'the view resolves the teacher''s display name'
);
select is(
  (select subject_name_ur from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  'فزکس',
  'the view carries the Urdu subject name for language-aware rendering'
);
select is(
  (select room_code from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  'R1',
  'the view resolves the room code'
);

-- ── AC: a Parent sees only their own child's section, only once Published ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'guardian_auth_uid')::text,
  true
);

select is(
  (select count(*)::int from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  1,
  'AC: a Parent can read the Published slot for their own child''s section'
);
select is(
  (select teacher_name from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  'Physics Teacher',
  'AC: the Parent sees the teacher''s display name'
);
select is(
  (select subject_name_en from public.v_section_timetable where slot_id = :'published_slot_a_id'),
  'Physics',
  'the Parent sees the English subject name too'
);
select is(
  (select count(*)::int from public.v_section_timetable where slot_id = :'draft_slot_a_id'),
  0,
  'AC: a Draft version stays invisible to a Parent, even for their own child''s section'
);
select is(
  (select count(*)::int from public.v_section_timetable where slot_id = :'published_slot_b_id'),
  0,
  'AC: a Parent requesting a section their child is not enrolled in gets zero rows'
);
select is(
  (select count(*)::int from public.class_section where id = :'section_a_id'),
  1,
  'the Parent can read their own child''s class_section row (fixes a real pre-existing gap this FR found)'
);
select is(
  (select count(*)::int from public.class_section where id = :'section_b_id'),
  0,
  'the Parent cannot read a section their child is not enrolled in'
);
select is(
  (select count(*)::int from public.timetable_version where id = :'published_version_id'),
  1,
  'the Parent can read the Published version row itself'
);
select is(
  (select count(*)::int from public.timetable_version where id = :'draft_version_id'),
  0,
  'the Parent cannot read the Draft version row'
);

-- AC (privacy): no channel exists for a Parent to read raw app_user rows —
-- teacher_name only ever reaches them through display_name_for_user(),
-- which returns nothing but the name.
select is(
  (select count(*)::int from public.app_user),
  0,
  'AC: a Parent has no direct read access to app_user at all — phone_e164 and every other staff column stay unreachable'
);
select is(
  app.display_name_for_user(:'teacher_user_id'::uuid),
  'Physics Teacher',
  'AC: display_name_for_user() is the one narrow channel a Parent has to a teacher''s name'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select * from finish();
rollback;
