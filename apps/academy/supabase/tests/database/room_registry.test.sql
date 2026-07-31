-- pgTAP tests for FR-E10: room and venue registry.
begin;
select plan(15);

select public.provision_tenant('test-room-co', 'Room Co', 'owner@roomco.test');
select id as tenant_id from public.tenant where slug = 'test-room-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

select public.provision_tenant('test-room-other-co', 'Room Other Co', 'owner@roomotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-room-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── create_room ───────────────────────────────────────────────────────

select public.create_room(:'campus_id'::uuid, '101', 'Room 101', 'CLASSROOM'::public.room_type_enum, 40) as room101_id \gset
select public.create_room(:'campus_id'::uuid, 'SL-1', 'Science Lab 1', 'SCIENCE_LAB'::public.room_type_enum, 30) as lab_id \gset
select is(
  (select room_type from public.room where id = :'lab_id'),
  'SCIENCE_LAB'::public.room_type_enum,
  'AC: a room can be created with type Science Lab and a capacity'
);

select throws_ok(
  format('select public.create_room(%L, %L, %L, %L, %L)', :'campus_id', '101', 'Duplicate Room', 'CLASSROOM', 40),
  'ROOM_CODE_DUPLICATE',
  'a second room coded 101 in the same campus is rejected'
);

-- AC: two campuses can both have a room coded '101' — scoped per campus,
-- not per tenant.
select public.create_campus('SOUTH', 'Campus South', null) as _unused \gset
select id as campus_south from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus_south')
  )::text,
  true
);
select lives_ok(
  format('select public.create_room(%L, %L, %L, %L, %L)', :'campus_south', '101', 'South Room 101', 'CLASSROOM', 40),
  'AC: room code 101 at Campus South succeeds despite 101 already existing at the first campus'
);

select throws_ok(
  format('select public.create_room(%L, %L, %L, %L, %L)', :'campus_id', 'ZERO', 'Zero Capacity Room', 'CLASSROOM', 0),
  'CAPACITY_MUST_BE_POSITIVE',
  'a room with zero capacity is rejected with the function''s own named error'
);

select throws_ok(
  format('select public.create_room(%L, %L, %L, %L, %L)', :'other_campus_id', 'X', 'Foreign Campus Room', 'CLASSROOM', 40),
  'CAMPUS_NOT_FOUND',
  'a foreign-tenant campus_id is refused'
);

-- ── set_room_active ──────────────────────────────────────────────────

select public.set_room_active(:'room101_id'::uuid, false, '2026-09-01'::date);
select is(
  (select is_active from public.room where id = :'room101_id'),
  false,
  'set_room_active can deactivate a room'
);
select is(
  (select inactive_from from public.room where id = :'room101_id'),
  '2026-09-01'::date,
  'the deactivation date is recorded'
);
select public.set_room_active(:'room101_id'::uuid, true);
select is(
  (select inactive_from from public.room where id = :'room101_id'),
  null::date,
  'reactivating a room clears its inactive_from date'
);

-- ── check_room_capacity ──────────────────────────────────────────────

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_name => 'A', p_capacity => 40) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Student One', '2014-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Student Two', '2014-01-01'::date, 'female') as s2 \gset
select public.create_student(:'campus_id'::uuid, 'Student Three', '2014-01-01'::date, 'male') as s3 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid);
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid);
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid);

select public.create_room(:'campus_id'::uuid, 'SMALL', 'Small Room', 'CLASSROOM'::public.room_type_enum, 2) as small_room_id \gset
select is(
  (public.check_room_capacity(:'small_room_id'::uuid, :'section_id'::uuid) ->> 'exceeded')::boolean,
  true,
  'AC: a 3-strength section in a 2-capacity room raises exceeded=true (non-blocking — the function itself never blocks)'
);
select is(
  (public.check_room_capacity(:'lab_id'::uuid, :'section_id'::uuid) ->> 'exceeded')::boolean,
  false,
  'the same section in a 30-capacity room is not flagged as exceeding'
);

-- ── suggest_rooms_for_type ───────────────────────────────────────────

select (
  select code from public.suggest_rooms_for_type(:'campus_id'::uuid, 'SCIENCE_LAB'::public.room_type_enum) limit 1
) as first_suggested \gset
select is(
  :'first_suggested'::text,
  'SL-1'::text,
  'AC: for a Science Lab preference, the Science Lab room is suggested ahead of classrooms'
);

-- ── tenant isolation ──────────────────────────────────────────────────

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@roomotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);

select is(
  (select count(*)::int from public.room),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero rooms via RLS despite 3 existing in the first tenant'
);
select throws_ok(
  format('select public.check_room_capacity(%L, %L)', :'small_room_id', :'section_id'),
  'ROOM_NOT_FOUND',
  'check_room_capacity refuses a foreign-tenant room id'
);
select is(
  (select count(*)::int from public.suggest_rooms_for_type(:'other_campus_id'::uuid, 'CLASSROOM'::public.room_type_enum)),
  0,
  'suggest_rooms_for_type never returns a foreign tenant''s rooms'
);
select throws_ok(
  format('select public.set_room_active(%L, %L)', :'room101_id', false),
  'ROOM_NOT_FOUND',
  'set_room_active refuses a foreign-tenant room id'
);

select * from finish();
rollback;
