-- pgTAP tests for FR-F15 (timetable print and export).
--
-- The PDF itself is produced outside the database (headless Chromium, see
-- apps/academy/lib/timetable-export/pdf.ts) and is asserted on in
-- e2e/timetable-print-and-export.spec.ts, which downloads the signed URL
-- and checks the real bytes. What is tested here is everything the
-- database is actually responsible for: who may request which layout, what
-- scope gets frozen onto the job row, what the render payload is allowed
-- to contain for that scope, who can read the job afterwards, and the
-- 30-day purge.
begin;
select plan(34);

select public.provision_tenant('test-ttexport-co', 'TT Export Co', 'owner@ttexport.test');
select id as tenant_id from public.tenant where slug = 'test-ttexport-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus2_id \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@ttexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'TT Export Owner');

select gen_random_uuid() as ayesha_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ayesha_uid', 'ayesha@ttexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ayesha_uid', :'tenant_id', 'class_teacher', 'Ms Ayesha');

select gen_random_uuid() as bilal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bilal_uid', 'bilal@ttexport.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bilal_uid', :'tenant_id', 'subject_teacher', 'Mr Bilal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_uid')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset
select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.create_subject('ISL', 'Islamiat', 'اسلامیات') as islamiat_id \gset
select public.assign_class_teacher(:'section_a_id'::uuid, :'ayesha_uid'::uuid, current_date - 30);

-- A published version at the home campus with a slot for each teacher, and
-- an unrelated version at campus2 for the campus-scope tests.
reset role;
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'Term 1', 'PUBLISHED', 1, current_date - 1)
returning id as version_id \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no)
values (:'tenant_id', :'campus2_id', :'session_id', 'MORNING', 'South draft', 'DRAFT', 1)
returning id as south_version_id \gset

insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
values (:'tenant_id', :'campus_id', :'version_id', :'section_a_id', 1, 1, :'physics_id', :'ayesha_uid')
returning id as ayesha_slot_id \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id)
values (:'tenant_id', :'campus_id', :'version_id', :'section_b_id', 2, 1, :'islamiat_id', :'bilal_uid')
returning id as bilal_slot_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_uid')::text,
  true
);

-- ── request_timetable_export: role and campus gating ───────────────────

select throws_ok(
  format($$ select public.request_timetable_export(%L, 'section'::public.timetable_export_layout) $$, gen_random_uuid()),
  'VERSION_NOT_FOUND',
  'a version id from another tenant is not found, not silently exported'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'section'::public.timetable_export_layout) $$, :'version_id'),
  'FORBIDDEN',
  'a role with no timetable duties at all cannot export'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'master'::public.timetable_export_layout) $$, :'south_version_id'),
  'FORBIDDEN',
  'a Principal scoped to one campus cannot export another campus''s timetable'
);
select lives_ok(
  format($$ select public.request_timetable_export(%L, 'master'::public.timetable_export_layout) $$, :'version_id'),
  'the same Principal can export the master grid for their own campus'
);

-- ── AC6: a Teacher only ever gets their own per-teacher sheet ──────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'bilal_uid')::text,
  true
);

select throws_ok(
  format($$ select public.request_timetable_export(%L, 'master'::public.timetable_export_layout) $$, :'version_id'),
  'EXPORT_SCOPE_FORBIDDEN',
  'AC6: a subject teacher cannot export the master grid'
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'section'::public.timetable_export_layout) $$, :'version_id'),
  'EXPORT_SCOPE_FORBIDDEN',
  'AC6: a subject teacher cannot export a section sheet'
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'teacher'::public.timetable_export_layout, %L) $$, :'version_id', :'ayesha_uid'),
  'EXPORT_SCOPE_FORBIDDEN',
  'AC6: a subject teacher cannot export a colleague''s per-teacher sheet'
);

select public.request_timetable_export(:'version_id'::uuid, 'teacher'::public.timetable_export_layout) as bilal_job_id \gset
select is(
  (select scope_staff_id from public.timetable_export_job where id = :'bilal_job_id'),
  :'bilal_uid'::uuid,
  'AC6: a teacher''s own request is frozen onto the job scoped to themselves'
);
select is(
  (select status::text from public.timetable_export_job where id = :'bilal_job_id'),
  'running',
  'the job starts in running, for the renderer to complete or fail'
);

-- ── AC6: the payload obeys the job''s stored scope, not the caller ─────

select is(
  jsonb_array_length(public.timetable_export_payload(:'bilal_job_id'::uuid) -> 'slots'),
  1,
  'AC6: the scoped payload carries exactly the requesting teacher''s own periods'
);
select is(
  (public.timetable_export_payload(:'bilal_job_id'::uuid) -> 'slots' -> 0 ->> 'subject_code'),
  'ISL',
  'AC6: and it is his own subject, not his colleague''s'
);
select is(
  jsonb_array_length(public.timetable_export_payload(:'bilal_job_id'::uuid) -> 'teachers'),
  1,
  'AC6: exactly one teacher sheet is produced'
);
select is(
  (public.timetable_export_payload(:'bilal_job_id'::uuid) -> 'slots' -> 0 ->> 'subject_name_ur'),
  'اسلامیات',
  'AC4: the payload carries the Urdu subject name the sheet prints'
);

-- ── A Class Teacher gets the section sheet for their own sections only ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ayesha_uid')::text,
  true
);
select public.request_timetable_export(:'version_id'::uuid, 'section'::public.timetable_export_layout) as ayesha_job_id \gset
select is(
  (select scope_section_ids from public.timetable_export_job where id = :'ayesha_job_id'),
  array[:'section_a_id'::uuid],
  'a class teacher''s section export is frozen to the section she is class teacher of'
);
select is(
  jsonb_array_length(public.timetable_export_payload(:'ayesha_job_id'::uuid) -> 'sections'),
  1,
  'and the payload contains only that section, never section B'
);
select is(
  (public.timetable_export_payload(:'ayesha_job_id'::uuid) -> 'sections' -> 0 ->> 'id'),
  :'section_a_id',
  'the one section in the payload is her own'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'bilal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_timetable_export(%L, 'section'::public.timetable_export_layout) $$, :'version_id'),
  'EXPORT_SCOPE_FORBIDDEN',
  'a class_teacher who is class teacher of nothing gets no section sheet at all'
);

-- ── AC2: the header fields every printed page carries ──────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_uid')::text,
  true
);
select public.request_timetable_export(:'version_id'::uuid, 'section'::public.timetable_export_layout) as owner_job_id \gset
select public.timetable_export_payload(:'owner_job_id'::uuid) as owner_payload \gset

select is((:'owner_payload'::jsonb -> 'tenant' ->> 'name'), 'TT Export Co', 'AC2: the payload carries the school name for the sheet header');
select is((:'owner_payload'::jsonb -> 'version' ->> 'version_no'), '1', 'AC2: and the timetable version number');
select is((:'owner_payload'::jsonb -> 'session' ->> 'id'), :'session_id', 'AC2: and the academic session');
select is((:'owner_payload'::jsonb -> 'campus' ->> 'id'), :'campus_id', 'AC2: and the campus');
select is(jsonb_array_length(:'owner_payload'::jsonb -> 'sections'), 2, 'AC1: an unscoped section export covers every active section of the campus');
select is(jsonb_array_length(:'owner_payload'::jsonb -> 'slots'), 2, 'an unscoped export carries every teacher''s slots');

-- ── Job RLS ────────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ayesha_uid')::text,
  true
);
select is(
  (select count(*)::int from public.timetable_export_job where id = :'bilal_job_id'),
  0,
  'a teacher cannot even see that a colleague requested an export'
);
select is(
  (select count(*)::int from public.timetable_export_job where id = :'ayesha_job_id'),
  1,
  'but can see her own'
);
-- timetable_export_payload is SECURITY DEFINER, so it sees the row and
-- then refuses it by name rather than pretending it does not exist —
-- the same "explain why" posture every other access-controlled function in
-- this codebase takes (FR-F12's own header).
select throws_ok(
  format($$ select public.timetable_export_payload(%L) $$, :'bilal_job_id'),
  'FORBIDDEN',
  'and cannot read a colleague''s render payload'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus2_id'), 'sub', :'ayesha_uid')::text,
  true
);
select is(
  (select count(*)::int from public.timetable_export_job where id = :'owner_job_id'),
  0,
  'a Principal scoped to another campus cannot see this campus''s export jobs'
);

-- ── AC5: the download link is minted with a 24-hour expiry ─────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_uid')::text,
  true
);
select public.complete_timetable_export(
  :'owner_job_id'::uuid,
  :'campus_id' || '/' || :'owner_job_id' || '/timetable-section.pdf',
  2, 0, 'http://127.0.0.1:54321/storage/v1/object/sign/timetable-exports/x?token=y', 'Noto Nastaliq Urdu'
);
select is(
  (select round(extract(epoch from (download_expires_at - completed_at)) / 3600)::int from public.timetable_export_job where id = :'owner_job_id'),
  24,
  'AC5: the recorded link expiry is 24 hours after completion'
);
select is(
  (select status::text from public.timetable_export_job where id = :'owner_job_id'),
  'completed',
  'the job records its own completion'
);

-- ── Storage bucket ─────────────────────────────────────────────────────

reset role;
select is((select public from storage.buckets where id = 'timetable-exports'), false, 'the timetable-exports bucket is private');
select is(
  (select allowed_mime_types from storage.buckets where id = 'timetable-exports'),
  array['application/pdf'],
  'and accepts PDFs only'
);

-- ── 30-day purge ───────────────────────────────────────────────────────

update public.timetable_export_job set requested_at = now() - interval '40 days' where id = :'owner_job_id';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  $$ select public.purge_timetable_exports() $$,
  'FORBIDDEN',
  'only an Owner (or the un-authenticated System actor) may run the purge'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus2_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (public.purge_timetable_exports() ->> 'jobs_deleted')::int,
  1,
  'the purge removes the 40-day-old export job'
);
select is(
  (select count(*)::int from public.timetable_export_job where id = :'ayesha_job_id'),
  1,
  'and leaves a job requested today alone'
);

select * from finish();
rollback;
