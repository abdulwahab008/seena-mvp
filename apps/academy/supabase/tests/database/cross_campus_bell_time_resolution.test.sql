-- pgTAP tests for 20260801010000_cross_campus_bell_time_resolution.sql.
--
-- The defect: 20260731770000_security_definer_campus_scope_audit.sql
-- made resolve_bell_template() return NULL for a campus outside the
-- caller's campus_ids claim, and teacher_timetable() — which is
-- deliberately cross-campus — then rendered its foreign-campus periods
-- with blank clock times instead of raising anything.
--
-- So this file proves BOTH halves at once, with ONE teacher whose claim
-- covers campus A only (teacher_timetable_view.test.sql seeds Ms Ayesha
-- with both campuses in her claim, which is precisely the case that
-- never exercised the bug):
--   * through teacher_timetable(), her campus B period resolves campus
--     B's own real bell time;
--   * calling resolve_bell_template() for campus B directly, as that
--     same authenticated teacher, still returns NULL — the audit's guard
--     is untouched for ordinary callers;
--   * the internal escape hatch is not reachable by `authenticated` at
--     all, so it cannot be used to route around that guard.
begin;
select plan(9);

select public.provision_tenant('test-xcampus-bell-co', 'Cross Campus Bell Co', 'owner@xcampusbell.test');
select id as tenant_id from public.tenant where slug = 'test-xcampus-bell-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@xcampusbell.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as ayesha_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ayesha_user_id', 'ayesha@xcampusbell.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ayesha_user_id', :'tenant_id', 'subject_teacher', 'Ms Ayesha');

select gen_random_uuid() as absent_teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'absent_teacher_user_id', 'absent@xcampusbell.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'absent_teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Absent');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);

-- Same superuser bracketing every other suite uses for campus: no INSERT
-- policy exists for `authenticated` on it.
reset role;
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
-- Matches exactly what gets scheduled below (campus A: 1 period; campus
-- B: Ms Ayesha's own + Mr Absent's = 2) so publish_timetable()'s quota
-- gate (FR-F09) never blocks this file's own, unrelated assertions.
select public.upsert_class_subject(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 1::smallint);
select public.upsert_class_subject(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 2::smallint);

select public.create_staff_teachable_subject(:'ayesha_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'absent_teacher_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

-- Period 1 runs at a DIFFERENT clock time per campus, so "resolved the
-- right template" and "resolved anything at all" can't be confused.
select public.create_bell_template(
  :'campus_a_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'North Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40')),
  true
) as template_a_id \gset
select public.create_bell_template(
  :'campus_b_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'South Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')),
  true
) as template_b_id \gset

select public.create_timetable_version(:'campus_a_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'North Draft') as version_a_id \gset
select public.create_timetable_version(:'campus_b_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'South Draft') as version_b_id \gset

select extract(dow from date '2026-08-03')::smallint as weekday_a \gset
select (date '2026-08-03' + 1) as ref_date_b \gset
select extract(dow from :'ref_date_b'::date)::smallint as weekday_b \gset
select (date '2026-08-03' + 2) as ref_date_sub \gset
select extract(dow from :'ref_date_sub'::date)::smallint as weekday_sub \gset

select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_a_id'::uuid, :'weekday_a'::smallint, 1::smallint, :'physics_id'::uuid, :'ayesha_user_id'::uuid) as slot_a_id \gset
select public.upsert_timetable_slot(:'version_b_id'::uuid, :'section_b_id'::uuid, :'weekday_b'::smallint, 1::smallint, :'physics_id'::uuid, :'ayesha_user_id'::uuid) as slot_b_id \gset

-- Mr Absent's own campus B period, which Ms Ayesha covers this week —
-- the substitution arm resolves its times through the same call.
select public.upsert_timetable_slot(:'version_b_id'::uuid, :'section_b_id'::uuid, :'weekday_sub'::smallint, 1::smallint, :'physics_id'::uuid, :'absent_teacher_user_id'::uuid) as slot_sub_id \gset

select public.publish_timetable(:'version_a_id'::uuid, '2026-01-01'::date) as published_a_id \gset
select public.publish_timetable(:'version_b_id'::uuid, '2026-01-01'::date) as published_b_id \gset

select public.create_substitution(:'slot_sub_id'::uuid, :'ref_date_sub'::date, :'ayesha_user_id'::uuid, 'other') as substitution_id \gset

-- ── Ms Ayesha, scoped to campus A ONLY ──────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'ayesha_user_id')::text,
  true
);

select isnt(
  (select start_time from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_b_id' and not is_substitution),
  null,
  'a teacher scoped to campus A only gets a REAL (non-null) start time for her campus B period'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_b_id' and not is_substitution),
  '09:00:00',
  'and it is campus B''s OWN bell time, not campus A''s'
);
select is(
  (select end_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_b_id' and not is_substitution),
  '09:40:00',
  'the end time resolves from campus B''s template too'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  '08:00:00',
  'her own in-scope campus A period is unaffected'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where is_substitution),
  '09:00:00',
  'the substitution arm resolves a foreign-campus cover period''s real time as well'
);

-- ── The audit's guard still holds for ordinary, direct callers ──────────

select is(
  (select public.resolve_bell_template(:'campus_b_id'::uuid, 'MORNING'::public.section_shift, '2026-08-04'::date)),
  null,
  'the campus guard still holds: the SAME teacher calling resolve_bell_template() directly for campus B gets NULL'
);
select is(
  (select public.resolve_bell_template(:'campus_a_id'::uuid, 'MORNING'::public.section_shift, '2026-08-03'::date)),
  :'template_a_id'::uuid,
  'and her own campus A still resolves normally through the public function'
);

-- A campus-scoped role other than the teacher herself: same guard, so
-- the escape hatch did not soften the function for anybody.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);
select is(
  (select public.resolve_bell_template(:'campus_b_id'::uuid, 'MORNING'::public.section_shift, '2026-08-04'::date)),
  null,
  'a Principal scoped to campus A gets NULL for campus B too'
);

-- ── The escape hatch is not a general-purpose bypass ────────────────────
-- `authenticated` holds USAGE on schema app (foundation.sql), so EXECUTE
-- being revoked is the only thing standing between a caller and the
-- unguarded resolver — assert it directly rather than trusting the grant.

select throws_ok(
  format($$ select app.resolve_bell_template_unscoped(%L::uuid, 'MORNING'::public.section_shift, '2026-08-04'::date) $$, :'campus_b_id'),
  '42501',
  null,
  'authenticated cannot call the unscoped resolver directly — the guard cannot be routed around'
);

select * from finish();
rollback;
