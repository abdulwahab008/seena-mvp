-- pgTAP tests for FR-F06 (room double-booking prevention).
begin;
select plan(14);

select public.provision_tenant('test-room-clash', 'Room Clash Co', 'owner@roomclash.test');
select id as tenant_id from public.tenant where slug = 'test-room-clash' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@roomclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_a_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_a_id', 'teacher-a@roomclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_a_id', :'tenant_id', 'subject_teacher', 'Teacher A');

select gen_random_uuid() as teacher_b_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_b_id', 'teacher-b@roomclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_b_id', :'tenant_id', 'subject_teacher', 'Teacher B');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset

select public.create_subject('ISL', 'Islamiyat', 'اسلامیات') as isl_id \gset
select public.create_subject('PHY', 'Physics', 'فزکس') as phy_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'isl_id'::uuid, 1::smallint);
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy_id'::uuid, 1::smallint);

-- Small capacity, deliberately less than the two sections' combined 40+40,
-- so AC4's overflow warning has something real to trigger on.
select public.create_room(:'campus_id'::uuid, 'HALL', 'The Hall', 'CLASSROOM'::public.room_type_enum, 50) as hall_id \gset
select public.create_room(:'campus_id'::uuid, 'R1', 'Room 1', 'CLASSROOM'::public.room_type_enum, 30) as room1_id \gset

select public.create_staff_teachable_subject(:'teacher_a_id'::uuid, :'isl_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_a_id'::uuid, :'phy_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_b_id'::uuid, :'isl_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_b_id'::uuid, :'phy_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')
  ),
  true
);

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft v1') as version_id \gset

-- ── AC3: a slot with no room is never clash-checked ────────────────────

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, 1::smallint, 2::smallint, :'phy_id'::uuid, :'teacher_a_id'::uuid) as no_room_slot_id \gset
select ok(:'no_room_slot_id' is not null, 'AC3: a slot with no room_id saves without any room clash check');

-- ── baseline: section A books Islamiyat in the Hall ─────────────────────

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, 1::smallint, 1::smallint, :'isl_id'::uuid, :'teacher_a_id'::uuid, :'hall_id'::uuid) as isl_a_slot_id \gset
select ok(:'isl_a_slot_id' is not null, 'section A books Islamiyat in the Hall');

-- ── AC1: a DIFFERENT subject competing for the same room/time is rejected ──

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 1::smallint, %L, %L, %L) $$,
    :'version_id', :'section_b_id', :'phy_id', :'teacher_b_id', :'hall_id'
  ),
  'ROOM_CLASH: section A at 08:00-08:40',
  'AC1: a different subject booked into an already-occupied room at the same time is rejected, naming the section and clock time'
);
select is(
  (select count(*)::int from public.timetable_slot where room_id = :'hall_id'),
  1,
  'AC1: the rejected write never actually saved a second row into the Hall'
);

-- ── AC2: the SAME subject, a different section, is a deliberate combine ──

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_b_id'::uuid, 1::smallint, 1::smallint, :'isl_id'::uuid, :'teacher_b_id'::uuid, :'hall_id'::uuid) as isl_b_slot_id \gset
select ok(:'isl_b_slot_id' is not null, 'AC2: section B joins the same Islamiyat lecture in the Hall without a clash');
select is(
  (select count(*)::int from public.timetable_slot where room_id = :'hall_id' and weekday = 1 and period_no = 1),
  2,
  'AC2: both sections'' slots now sit in the Hall at the same time'
);
select isnt(
  (select staff_id from public.timetable_slot where id = :'isl_a_slot_id'),
  (select staff_id from public.timetable_slot where id = :'isl_b_slot_id'),
  'AC2: each combined section keeps its own independent teacher'
);

-- ── AC4: the combined booking overflows the Hall''s capacity — a warning, not a block ──

select is(
  (select total_students from public.timetable_room_capacity_warning where timetable_version_id = :'version_id' and room_id = :'hall_id' and weekday = 1 and period_no = 1),
  80,
  'AC4: the warning records the two sections'' combined size (40+40)'
);
select is(
  (select room_capacity from public.timetable_room_capacity_warning where timetable_version_id = :'version_id' and room_id = :'hall_id' and weekday = 1 and period_no = 1),
  50,
  'AC4: the warning records the Hall''s own actual capacity'
);
select is(
  (select count(*)::int from public.timetable_slot where room_id = :'hall_id' and weekday = 1 and period_no = 1),
  2,
  'AC4: the overflowing write still saved — a warning, never a block'
);

-- Re-saving the section A slot into a room with enough capacity (R1)
-- un-combines it — the Hall's warning for that cell must not survive
-- pointing at a pairing that no longer exists.
select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, 1::smallint, 1::smallint, :'isl_id'::uuid, :'teacher_a_id'::uuid, :'room1_id'::uuid) as isl_a_moved_id \gset
select is(:'isl_a_moved_id'::uuid, :'isl_a_slot_id'::uuid, 're-saving the same cell into a different room updates in place');
select is(
  (select count(*)::int from public.timetable_room_capacity_warning where timetable_version_id = :'version_id' and room_id = :'hall_id' and weekday = 1 and period_no = 1),
  0,
  'moving one combined member out of the Hall clears that cell''s own capacity warning'
);

-- ── clear_timetable_slot() also drops a cell''s own capacity warning ──────

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, 1::smallint, 1::smallint, :'isl_id'::uuid, :'teacher_a_id'::uuid, :'hall_id'::uuid) as isl_a_back_id \gset
select is(
  (select count(*)::int from public.timetable_room_capacity_warning where timetable_version_id = :'version_id' and room_id = :'hall_id' and weekday = 1 and period_no = 1),
  1,
  'moving section A back into the Hall re-triggers the overflow warning'
);
select public.clear_timetable_slot(:'version_id'::uuid, :'section_a_id'::uuid, 1::smallint, 1::smallint);
select is(
  (select count(*)::int from public.timetable_room_capacity_warning where timetable_version_id = :'version_id' and room_id = :'hall_id' and weekday = 1 and period_no = 1),
  0,
  'clearing a combined member''s own slot also clears the Hall''s capacity warning for that cell'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select * from finish();
rollback;
