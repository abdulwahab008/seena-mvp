-- pgTAP tests for FR-F05 (teacher double-booking prevention).
--
-- AC #4 ("20 concurrent writes, exactly 1 commits") needs real concurrent
-- Postgres backends, which a single-connection pgTAP transaction can't
-- produce — that AC is proven in the e2e spec instead, via genuinely
-- parallel RPC calls.
begin;
select plan(12);

select public.provision_tenant('test-clash-co', 'Clash Co', 'owner@clashco.test');
select id as tenant_id from public.tenant where slug = 'test-clash-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@clashco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@clashco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Kamran');

-- A second campus, with its OWN default bell template whose period 2 has
-- a DIFFERENT clock time than the first campus's period 2 — the exact
-- setup AC #2/#3 need.
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus2_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_9a_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_9b_id \gset
select public.create_section(:'campus2_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'C', 40) as section_south_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 5::smallint) as cs_north \gset
select public.upsert_class_subject(:'campus2_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 5::smallint) as cs_south \gset
-- FR-D03: upsert_timetable_slot() now also checks teach-scope.
select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

-- Campus North: period 2 is 09:00-09:40.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'North Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')
  ),
  true
) as north_template_id \gset

-- Campus South: period 2 is ALSO 09:00-09:40 (same clock time as North —
-- AC #2's clash-across-campuses case). Period 1 (08:45-08:55) is
-- deliberately clear of both North's period 1 (08:00-08:40) and South's
-- own period 2 (09:00-09:40) — AC #3's "same period number, no overlap"
-- case needs these to be genuinely non-overlapping, not just numbered
-- the same.
select public.create_bell_template(
  :'campus2_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'South Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:45', 'end_time', '08:55'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')
  ),
  true
) as south_template_id \gset

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'North Draft') as north_version_id \gset
select public.create_timetable_version(:'campus2_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'South Draft') as south_version_id \gset

-- ── AC #1: same version, same clock time, different sections ───────────

select public.upsert_timetable_slot(:'north_version_id'::uuid, :'section_9a_id'::uuid, 1::smallint, 2::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as slot_9a \gset

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 2::smallint, %L, %L) $$,
    :'north_version_id', :'section_9b_id', :'physics_id', :'teacher_user_id'
  ),
  'TEACHER_CLASH: section A at 09:00-09:40',
  'AC: assigning the same teacher to 9-B at the same clock time is rejected, naming section 9-A and the clash time'
);

-- ── AC #2: a clash across two DIFFERENT campuses/versions, same clock time ──

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 1::smallint, 2::smallint, %L, %L) $$,
    :'south_version_id', :'section_south_id', :'physics_id', :'teacher_user_id'
  ),
  'TEACHER_CLASH: section A at 09:00-09:40',
  'AC: the clash is detected even though the two slots live in different campuses and timetable versions'
);

-- ── AC #3: same period_no, different bell templates, DIFFERENT clock times ──
-- North period 1 is 08:00-08:40; South period 1 is 08:45-08:55 — no
-- overlap, so no clash even though both are "period 1".

select public.upsert_timetable_slot(:'south_version_id'::uuid, :'section_south_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as slot_south_p1 \gset
select public.upsert_timetable_slot(:'north_version_id'::uuid, :'section_9b_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as slot_9b_p1 \gset
select ok(
  :'slot_9b_p1' is not null,
  'AC: period 1 at both campuses resolves to different clock times, so no clash is raised even though the period number is the same'
);

-- ── overwriting the SAME cell is never a self-clash ─────────────────────

select public.upsert_timetable_slot(:'north_version_id'::uuid, :'section_9a_id'::uuid, 1::smallint, 2::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid, null, null, null, 'updated note') as slot_9a_again \gset
select is(:'slot_9a_again'::uuid, :'slot_9a'::uuid, 're-saving the same cell for the same teacher is not treated as a clash against itself');

-- ── a different weekday never clashes ───────────────────────────────────

select public.upsert_timetable_slot(:'north_version_id'::uuid, :'section_9b_id'::uuid, 2::smallint, 2::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid) as slot_tuesday \gset
select ok(:'slot_tuesday' is not null, 'the same teacher, same clock time, but a different weekday is never a clash');

-- ── an unstaffed slot never triggers the clash check ────────────────────

select public.upsert_timetable_slot(:'north_version_id'::uuid, :'section_9b_id'::uuid, 3::smallint, 2::smallint, :'physics_id'::uuid) as slot_no_teacher \gset
select ok(:'slot_no_teacher' is not null, 'a slot with no teacher assigned never runs the clash check');

-- ── v_slot_clock_time ────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.v_slot_clock_time where slot_id = :'slot_9a'::uuid),
  1,
  'the staffed 9-A slot appears in v_slot_clock_time'
);
select is(
  (select start_time::text from public.v_slot_clock_time where slot_id = :'slot_9a'::uuid),
  '09:00:00',
  'v_slot_clock_time resolves the correct start time via the campus''s bell template'
);
select is(
  (select count(*)::int from public.v_slot_clock_time where slot_id = :'slot_no_teacher'::uuid),
  0,
  'an unstaffed slot never appears in v_slot_clock_time'
);

-- ── resolve_bell_template_for_weekday ────────────────────────────────────

select is(
  public.resolve_bell_template_for_weekday(:'campus_id'::uuid, 'MORNING'::public.section_shift, 1::smallint),
  :'north_template_id'::uuid,
  'AC-adjacent: with no weekday rule, Monday resolves to the campus default template'
);

-- ── authorization ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 4::smallint, 1::smallint, %L, %L) $$,
    :'north_version_id', :'section_9a_id', :'physics_id', :'teacher_user_id'
  ),
  'FORBIDDEN',
  'a subject teacher cannot write to the timetable grid'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── RLS: v_slot_clock_time (security_invoker) respects the base table's own scope ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus2_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.v_slot_clock_time where slot_id = :'slot_9a'::uuid),
  0,
  'a staff member scoped to a different campus cannot see this slot via v_slot_clock_time either'
);

select * from finish();
rollback;
