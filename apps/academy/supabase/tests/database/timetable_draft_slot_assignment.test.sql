-- pgTAP tests for FR-F04 (draft slot assignment).
begin;
select plan(17);

select public.provision_tenant('test-slot-co', 'Slot Co', 'owner@slotco.test');
select id as tenant_id from public.tenant where slug = 'test-slot-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@slotco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@slotco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'A Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 5::smallint) as cs_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'chem_id'::uuid, 5::smallint) as cs_id2 \gset

-- A home room + a primary Physics teacher, so prefill has something to find.
select public.create_room(:'campus_id'::uuid, 'R1', 'Room 1', 'CLASSROOM'::public.room_type_enum, 30) as room_id \gset
reset role;
update public.class_section set home_room_id = :'room_id'::uuid where id = :'section_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.assign_subject_teacher(:'section_id'::uuid, :'physics_id'::uuid, :'teacher_user_id'::uuid, current_date - 30);

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft v1') as version_id \gset

-- ── prefill_slot_defaults ─────────────────────────────────────────────────

select staff_id as prefill_staff, room_id as prefill_room
  from public.prefill_slot_defaults(:'section_id'::uuid, :'physics_id'::uuid) \gset

select is(:'prefill_staff'::uuid, :'teacher_user_id'::uuid, 'AC: prefill returns the section''s primary Physics teacher');
select is(:'prefill_room'::uuid, :'room_id'::uuid, 'AC: prefill returns the section''s home room');

-- ── upsert_timetable_slot: write, then overwrite the same cell ─────────────

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 3::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid, :'room_id'::uuid) as slot_id \gset
select is(
  (select subject_id from public.timetable_slot where id = :'slot_id'::uuid),
  :'physics_id'::uuid,
  'AC: Monday period 3 is written with Physics'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_id'::uuid and section_id = :'section_id'::uuid),
  1,
  'exactly one slot row exists for this cell'
);

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 3::smallint, :'chem_id'::uuid, null, null) as slot_id2 \gset
select is(
  :'slot_id2'::uuid,
  :'slot_id'::uuid,
  'writing the same (version, section, weekday, period) cell again upserts the same row, not a duplicate'
);
select is(
  (select subject_id from public.timetable_slot where id = :'slot_id'::uuid),
  :'chem_id'::uuid,
  'the upsert overwrote the subject to Chemistry'
);

-- ── SUBJECT_NOT_OFFERED ─────────────────────────────────────────────────

select public.create_subject('URD', 'Urdu', 'اردو') as urdu_id \gset
select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 2::smallint, 1::smallint, %L) $$,
    :'version_id', :'section_id', :'urdu_id'
  ),
  'SUBJECT_NOT_OFFERED',
  'AC: a subject absent from the class-subject map for this class level is rejected'
);

-- ── clear_timetable_slot ─────────────────────────────────────────────────

select public.clear_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, 3::smallint);
select is(
  (select count(*)::int from public.timetable_slot where id = :'slot_id'::uuid),
  0,
  'AC: clearing a slot deletes the row outright'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_id'::uuid and section_id = :'section_id'::uuid and weekday = 1 and period_no = 3),
  0,
  'the cell is free again — no leftover row of any kind'
);

-- ── VERSION_IMMUTABLE ─────────────────────────────────────────────────────
-- Nothing in this FR publishes a version yet (that's a future FR) —
-- simulated directly as ground truth, same convention as bell_template's
-- is_locked.

reset role;
update public.timetable_version set status = 'PUBLISHED' where id = :'version_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 4::smallint, 1::smallint, %L) $$,
    :'version_id', :'section_id', :'physics_id'
  ),
  'VERSION_IMMUTABLE',
  'AC: a write to a non-DRAFT version is rejected'
);
select throws_ok(
  format($$ select public.clear_timetable_slot(%L, %L, 1::smallint, 1::smallint) $$, :'version_id', :'section_id'),
  'VERSION_IMMUTABLE',
  'clearing a slot on a non-DRAFT version is also rejected'
);

reset role;
update public.timetable_version set status = 'DRAFT' where id = :'version_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── authorization ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 5::smallint, 1::smallint, %L) $$,
    :'version_id', :'section_id', :'physics_id'
  ),
  'FORBIDDEN',
  'a subject teacher cannot write to the timetable grid'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(gen_random_uuid(), %L, 5::smallint, 1::smallint, %L) $$,
    :'section_id', :'physics_id'
  ),
  'VERSION_NOT_FOUND',
  'an unknown version id is rejected'
);
select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, gen_random_uuid(), 5::smallint, 1::smallint, %L) $$,
    :'version_id', :'physics_id'
  ),
  'SECTION_NOT_FOUND',
  'an unknown section id is rejected'
);

-- ── RLS: cross-campus and cross-tenant isolation ────────────────────────

reset role;
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Second Campus', 'C2') returning id as campus2_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus2_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.timetable_version where id = :'version_id'::uuid),
  0,
  'a staff member scoped to a different campus cannot see this campus''s timetable version'
);

reset role;
select public.provision_tenant('test-slot-other', 'Other Slot Co', 'owner@otherslot.test');
select id as other_tenant_id from public.tenant where slug = 'test-slot-other' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', gen_random_uuid())::text,
  true
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_id'::uuid),
  0,
  'a different tenant entirely cannot see this timetable''s slots'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── realtime ─────────────────────────────────────────────────────────────

select ok(
  exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'timetable_slot'),
  'AC (Supabase Objects): timetable_slot is published for realtime so a co-builder''s grid updates live'
);

select * from finish();
rollback;
