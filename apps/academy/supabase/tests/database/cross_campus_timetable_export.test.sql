-- pgTAP tests for 20260801030000_cross_campus_timetable_export.sql.
--
-- The defect: 20260731770000_security_definer_campus_scope_audit.sql made
-- resolve_bell_template() and resolve_branding() return NULL for a campus
-- outside the caller's campus_ids claim. timetable_export_payload()
-- (FR-F15) resolves the printed sheet's period columns and header logo
-- through both, on the JOB's campus — so a teacher exporting a sheet for
-- a campus her claim does not cover got 'periods': [] and no logo, and
-- the renderer produced a real PDF with an empty time column. No error.
--
-- The cross-campus case is the visible one; the ordinary one is worse. A
-- teacher with no user_campus row claims '{}', and '{}' contains no
-- campus at all — so she got the same blank sheet for her OWN campus.
-- Both are asserted below.
--
-- The fix resolves both unscoped inside the payload (the job's frozen
-- scope is the authority, which is the whole reason that function is
-- SECURITY DEFINER) and moves AC6's campus check to request time, where
-- FR-F15 already says scope is decided. So this file also proves the
-- request-time refusal is loud, and that the guard the audit installed is
-- untouched for every ordinary, direct caller.
begin;
select plan(15);

select public.provision_tenant('test-xcampus-export-co', 'Cross Campus Export Co', 'owner@xcampusexport.test');
select id as tenant_id from public.tenant where slug = 'test-xcampus-export-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@xcampusexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Export Owner');

-- Ms Ayesha teaches at BOTH campuses; her claim covers campus A only.
select gen_random_uuid() as ayesha_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ayesha_uid', 'ayesha@xcampusexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ayesha_uid', :'tenant_id', 'subject_teacher', 'Ms Ayesha');

-- Mr Bilal teaches at campus A only — the caller who has no business
-- naming campus B's version at all.
select gen_random_uuid() as bilal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bilal_uid', 'bilal@xcampusexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bilal_uid', :'tenant_id', 'subject_teacher', 'Mr Bilal');

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Alpha', 40) as section_alpha \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Zulu', 40) as section_zulu \gset
select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset

-- Period 1 runs at a DIFFERENT clock time per campus, so "resolved campus
-- B's own template" and "resolved anything at all" cannot be confused.
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

-- A campus B logo AND a tenant-wide fallback, so "resolved campus B's own
-- asset" cannot be confused with "fell back to the tenant's".
reset role;
insert into public.branding_asset (tenant_id, campus_id, asset_type, storage_path, width_px, height_px, bytes, version, is_current)
values (:'tenant_id', null, 'logo', 'tenant/fallback-logo.png', 600, 600, 4096, 1, true);
insert into public.branding_asset (tenant_id, campus_id, asset_type, storage_path, width_px, height_px, bytes, version, is_current)
values (:'tenant_id', :'campus_b_id', 'logo', 'south/campus-b-logo.png', 600, 600, 4096, 1, true);

-- Versions and slots inserted directly, the same superuser bracketing
-- timetable_print_and_export.test.sql uses for the same rows.
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from)
values (:'tenant_id', :'campus_a_id', :'session_id', 'MORNING', 'North Term 1', 'PUBLISHED', 1, current_date - 1)
returning id as version_a_id \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from)
values (:'tenant_id', :'campus_b_id', :'session_id', 'MORNING', 'South Term 1', 'PUBLISHED', 1, current_date - 1)
returning id as version_b_id \gset

insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
values (:'tenant_id', :'campus_a_id', :'version_a_id', :'section_alpha', 1, 1, :'physics_id', :'ayesha_uid');
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
values (:'tenant_id', :'campus_b_id', :'version_b_id', :'section_zulu', 2, 1, :'physics_id', :'ayesha_uid');

set local role authenticated;

-- ── Ms Ayesha, claim = campus A only, exporting her campus B sheet ─────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'ayesha_uid')::text,
  true
);

select public.request_timetable_export(:'version_b_id'::uuid, 'teacher'::public.timetable_export_layout) as ayesha_b_job \gset
select public.timetable_export_payload(:'ayesha_b_job'::uuid) as ayesha_b_payload \gset

select is(
  jsonb_array_length(:'ayesha_b_payload'::jsonb -> 'periods'),
  1,
  'AC2: the printed sheet gets its period columns back — a teacher exporting a campus outside her claim no longer gets a timetable with no times'
);
select is(
  (:'ayesha_b_payload'::jsonb -> 'periods' -> 0 ->> 'start_time'),
  '09:00:00',
  'and they are campus B''s OWN bell times, not campus A''s'
);
select is(
  (:'ayesha_b_payload'::jsonb ->> 'logo_storage_path'),
  'south/campus-b-logo.png',
  'AC2: the campus logo comes back too, and it is campus B''s own rather than the tenant fallback'
);
select is(
  jsonb_array_length(:'ayesha_b_payload'::jsonb -> 'slots'),
  1,
  'AC6 still holds: the sheet carries exactly her own period, nobody else''s'
);
select is(
  (:'ayesha_b_payload'::jsonb -> 'slots' -> 0 ->> 'staff_id'),
  :'ayesha_uid',
  'and that period is hers'
);

-- ── The same defect without a second campus in sight ───────────────────
-- A teacher with no user_campus row claims '{}', which contains no campus
-- at all — so the guard blanked her OWN campus's sheet too.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(), 'sub', :'ayesha_uid')::text,
  true
);
select public.request_timetable_export(:'version_a_id'::uuid, 'teacher'::public.timetable_export_layout) as ayesha_a_job \gset
select is(
  (public.timetable_export_payload(:'ayesha_a_job'::uuid) -> 'periods' -> 0 ->> 'start_time'),
  '08:00:00',
  'a teacher whose campus_ids claim is empty gets real times for her own campus''s sheet'
);

-- ── The request-time refusal is loud, never a blank PDF ────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'bilal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'teacher'::public.timetable_export_layout) $$, :'version_b_id'),
  '42501',
  'EXPORT_SCOPE_FORBIDDEN',
  'AC6: a teacher with neither a claim on that campus nor a period in that version is refused outright, not handed an empty sheet'
);
select is(
  (select count(*)::int from public.timetable_export_job where timetable_version_id = :'version_b_id'::uuid and requested_by = :'bilal_uid'::uuid),
  0,
  'and no job row was created for the refused request'
);
select lives_ok(
  format($$ select public.request_timetable_export(%L, 'teacher'::public.timetable_export_layout) $$, :'version_a_id'),
  'while his own campus''s sheet is unaffected'
);

-- ── The audit's guard still holds for ordinary, direct callers ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'ayesha_uid')::text,
  true
);
select is(
  (select public.resolve_bell_template(:'campus_b_id'::uuid, 'MORNING'::public.section_shift, current_date)),
  null,
  'the campus guard is untouched: the SAME teacher calling resolve_bell_template() directly for campus B gets NULL'
);
select is(
  (select public.resolve_branding(:'campus_b_id'::uuid, 'logo'::public.branding_asset_type)),
  null,
  'and resolve_branding() for campus B gets NULL, not even the tenant fallback'
);
select is(
  (select public.resolve_branding(:'campus_a_id'::uuid, 'logo'::public.branding_asset_type) ->> 'storage_path'),
  'tenant/fallback-logo.png',
  'while her own campus A still resolves normally through the public function'
);
select is(
  (select count(*)::int from public.bell_template where campus_id = :'campus_b_id'::uuid),
  0,
  'and campus B''s bell templates are still unreadable to her directly — the payload discloses nothing she could fetch herself'
);
select throws_ok(
  format($$ select app.resolve_branding_unscoped(%L::uuid, 'logo'::public.branding_asset_type) $$, :'campus_b_id'),
  '42501',
  null,
  'authenticated cannot call the unscoped branding resolver directly — the guard cannot be routed around'
);

-- ── The admin branch is untouched ──────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'master'::public.timetable_export_layout) $$, :'version_b_id'),
  '42501',
  'FORBIDDEN',
  'a Principal scoped to campus A still cannot export campus B''s master grid'
);

select * from finish();
rollback;
