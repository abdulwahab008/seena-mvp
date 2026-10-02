-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module N: Parent & Student Portal
-- FR-N08: Moderated teacher remarks
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(23);

-- ─── 1. Setup Fixtures ─────────────────────────────────────────────────
select public.provision_tenant('test-remarks-acad', 'Remarks Academy', 'owner@remarks.test');
select id as tenant_id from public.tenant where slug = 'test-remarks-acad' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

-- Create users: Teacher, Principal, Guardian
insert into auth.users (id, email)
values
  ('11111111-1111-1111-1111-111111111111', 'teacher@remarks.test'),
  ('22222222-2222-2222-2222-222222222222', 'principal@remarks.test'),
  ('33333333-3333-3333-3333-333333333333', 'guardian@remarks.test');

-- Create staff roles in app_user and user_campus
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values
  ('11111111-1111-1111-1111-111111111111', :'tenant_id'::uuid, 'class_teacher', 'Teacher One'),
  ('22222222-2222-2222-2222-222222222222', :'tenant_id'::uuid, 'principal', 'Principal One');

insert into public.user_campus (user_id, tenant_id, campus_id)
values
  ('11111111-1111-1111-1111-111111111111', :'tenant_id'::uuid, :'campus_id'::uuid),
  ('22222222-2222-2222-2222-222222222222', :'tenant_id'::uuid, :'campus_id'::uuid);

-- Create student and guardian
insert into public.student (id, tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', :'tenant_id'::uuid, :'campus_id'::uuid, 'REM-001', 'Zayd Ali', '2015-05-15'::date, 'male', 'active');

insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164, email)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', :'tenant_id'::uuid, '33333333-3333-3333-3333-333333333333', 'Parent Ali', '+923001234567', 'guardian@remarks.test');

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing, receives_academic)
values (:'tenant_id'::uuid, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'father', true, true, true);

-- Initialize campus portal policy: require_remark_approval = true
insert into public.campus_portal_policy (campus_id, tenant_id, require_remark_approval)
values (:'campus_id'::uuid, :'tenant_id'::uuid, true)
on conflict (campus_id) do update set require_remark_approval = true;

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'campus_portal_policy', 'Table campus_portal_policy exists');
select has_table('public', 'student_remark', 'Table student_remark exists');
select has_table('public', 'student_remark_version', 'Table student_remark_version exists');
select has_table('public', 'remark_moderation_log', 'Table remark_moderation_log exists');
select has_table('public', 'teacher_remark_notification', 'Table teacher_remark_notification exists');

-- Check columns
select has_column('public', 'student_remark', 'current_version_id', 'student_remark has current_version_id');
select has_column('public', 'student_remark_version', 'body', 'student_remark_version has body');
select has_column('public', 'student_remark_version', 'language', 'student_remark_version has language');
select has_column('public', 'student_remark_version', 'rejection_reason', 'student_remark_version has rejection_reason');

-- ─── 3. AC 1: Approval Workflow & Guardian Visibility Gate ────────────
-- 3a. Teacher submits remark under active session
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'class_teacher',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '11111111-1111-1111-1111-111111111111'
  )::text,
  true
);

select public.submit_student_remark(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'Zayd demonstrated great enthusiasm in science project today.',
  'en'
);

select id as remark_id from public.student_remark where student_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid limit 1 \gset
select id as version_1_id from public.student_remark_version where remark_id = :'remark_id'::uuid and version_number = 1 \gset

-- Verify remark and version state
select is(
  (select status from public.student_remark where id = :'remark_id'::uuid),
  'pending',
  'FR-N08 AC 1a: Newly submitted remark has status pending when policy requires approval'
);

select is(
  (select current_version_id from public.student_remark where id = :'remark_id'::uuid),
  null,
  'FR-N08 AC 1a: current_version_id is null while pending approval'
);

-- 3b. Guardian views portal: remark is absent
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', '33333333-3333-3333-3333-333333333333'
  )::text,
  true
);

select is(
  (select count(*)::int from public.student_remark where student_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid),
  0,
  'FR-N08 AC 1b: Pending remark is hidden from guardian via RLS'
);

select is(
  (select count(*)::int from public.student_remark_version where id = :'version_1_id'::uuid),
  0,
  'FR-N08 AC 1b: Pending remark version is hidden from guardian via RLS'
);

-- 3c. Principal approves remark
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '22222222-2222-2222-2222-222222222222'
  )::text,
  true
);

select public.moderate_student_remark(:'version_1_id'::uuid, 'approved');

-- 3d. Guardian reloads portal: remark is now visible
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', '33333333-3333-3333-3333-333333333333'
  )::text,
  true
);

select is(
  (select count(*)::int from public.student_remark where student_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid),
  1,
  'FR-N08 AC 1c: Approved remark is visible to guardian in portal'
);

select is(
  (select body from public.student_remark_version where id = :'version_1_id'::uuid),
  'Zayd demonstrated great enthusiasm in science project today.',
  'FR-N08 AC 1c: Guardian can read approved version body text'
);

-- ─── 4. AC 2: Versioning on Edit & Previous Approved Stability ────────
-- Teacher edits the approved remark
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'class_teacher',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '11111111-1111-1111-1111-111111111111'
  )::text,
  true
);

select public.edit_student_remark(
  :'remark_id'::uuid,
  'Zayd demonstrated outstanding leadership and teamwork in science today.',
  'en'
);

select id as version_2_id from public.student_remark_version where remark_id = :'remark_id'::uuid and version_number = 2 \gset

select is(
  (select status from public.student_remark_version where id = :'version_2_id'::uuid),
  'pending',
  'FR-N08 AC 2: New version created with status pending'
);

-- Guardian inspects portal: previously approved version remains visible!
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', '33333333-3333-3333-3333-333333333333'
  )::text,
  true
);

select is(
  (select current_version_id from public.student_remark where id = :'remark_id'::uuid),
  :'version_1_id'::uuid,
  'FR-N08 AC 2: student_remark current_version_id still points to version 1'
);

select is(
  (select count(*)::int from public.student_remark_version where id = :'version_2_id'::uuid),
  0,
  'FR-N08 AC 2: Unapproved edited version 2 is hidden from guardian'
);

-- ─── 5. AC 3: Rejection with Teacher Reason & Guardian Privacy ─────────
-- Principal rejects version 2 with explanation
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '22222222-2222-2222-2222-222222222222'
  )::text,
  true
);

select public.moderate_student_remark(
  :'version_2_id'::uuid,
  'rejected',
  'Please specify the exact science chapter or project name.'
);

-- Teacher checks notifications
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'class_teacher',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '11111111-1111-1111-1111-111111111111'
  )::text,
  true
);

select ok(
  exists (
    select 1 from public.teacher_remark_notification
    where teacher_id = '11111111-1111-1111-1111-111111111111'
      and version_id = :'version_2_id'::uuid
      and type = 'remark_rejected'
      and rejection_reason = 'Please specify the exact science chapter or project name.'
  ),
  'FR-N08 AC 3: Teacher is notified with rejection reason'
);

-- Guardian still never sees version 2 rejected text
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', '33333333-3333-3333-3333-333333333333'
  )::text,
  true
);

select is(
  (select count(*)::int from public.student_remark_version where id = :'version_2_id'::uuid),
  0,
  'FR-N08 AC 3: Guardian never sees the rejected version text'
);

-- ─── 6. AC 4: Urdu Remark Storage & Immutable Versions ─────────────────
-- Reset role to postgres for setup
set local role postgres;

-- Teacher writes Urdu remark
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'class_teacher',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '11111111-1111-1111-1111-111111111111'
  )::text,
  true
);

select public.submit_student_remark(
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid,
  'طالب علم نے اردو املا میں شاندار کارکردگی کا مظاہرہ کیا ہے۔',
  'ur'
);

select id as urdu_remark_id from public.student_remark order by created_at desc limit 1 \gset
select id as urdu_version_id from public.student_remark_version where remark_id = :'urdu_remark_id'::uuid limit 1 \gset

-- Principal approves Urdu remark
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', '22222222-2222-2222-2222-222222222222'
  )::text,
  true
);

select public.moderate_student_remark(:'urdu_version_id'::uuid, 'approved');

-- Verify Urdu version details
select is(
  (select language from public.student_remark_version where id = :'urdu_version_id'::uuid),
  'ur',
  'FR-N08 AC 4: Urdu remark language is recorded as ur'
);

-- Test immutability trigger: cannot modify approved version
select throws_matching(
  format('update public.student_remark_version set body = ''tampered text'' where id = %L', :'urdu_version_id'),
  'Cannot modify an approved or rejected remark version',
  'FR-N08 Notes: Immutable version trigger prevents altering approved remark version'
);

-- Test immutability trigger: cannot delete approved version
select throws_matching(
  format('delete from public.student_remark_version where id = %L', :'urdu_version_id'),
  'Cannot delete an approved or rejected remark version',
  'FR-N08 Notes: Immutability trigger prevents deleting approved remark version'
);

select finish();
rollback;
