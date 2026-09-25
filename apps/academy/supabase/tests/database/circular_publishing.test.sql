-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M12: Circular publishing with attachments
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(12);

-- ─── 1. Setup Test Fixtures (as postgres) ──────────────────────────────────
select public.provision_tenant('test-circular-pub', 'Circular Academy', 'owner@circular.test');
select id as tenant_id from public.tenant where slug = 'test-circular-pub' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

-- Create Admin / Principal User
select gen_random_uuid() as admin_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_id', 'principal@circular.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_id', :'tenant_id', 'owner', 'Principal Skinner');

-- Switch to admin auth context
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_id'
  )::text,
  true
);

-- Use existing academic session provisioned with tenant
select id as session_id from public.academic_session where tenant_id = :'tenant_id'::uuid limit 1 \gset

-- Select existing classes seeded by provision_tenant
select id as class_9_id from public.class_level where tenant_id = :'tenant_id'::uuid and name_en = 'Class 9' limit 1 \gset
select id as class_8_id from public.class_level where tenant_id = :'tenant_id'::uuid and name_en = 'Class 8' limit 1 \gset

-- Create sections using helper
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class_9_id'::uuid, 'Pre-Medical', 40) as sec_9_med_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class_8_id'::uuid, 'Section-8A', 40) as sec_8_a_id \gset

-- Create Students & Enrolments using helpers
select public.create_student(:'campus_id'::uuid, 'Ali Khan', '2010-05-10'::date, 'male') as s1_id \gset
select public.enrol_student(:'sec_9_med_id'::uuid, :'s1_id'::uuid) as enrol1_id \gset

select public.create_student(:'campus_id'::uuid, 'Bilal Ahmed', '2011-06-15'::date, 'male') as s2_id \gset
select public.enrol_student(:'sec_8_a_id'::uuid, :'s2_id'::uuid) as enrol2_id \gset

-- Guardian 1 (Parent of Ali Khan - Class 9)
select gen_random_uuid() as g1_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'g1_user_id', 'parent9@circular.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'g1_user_id', :'tenant_id', 'parent', 'Tariq Khan');

select gen_random_uuid() as g1_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'g1_id', :'tenant_id'::uuid, :'g1_user_id'::uuid, 'Tariq Khan', '+923009990001');

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'s1_id'::uuid, :'g1_id'::uuid, 'father', true, true);

-- Guardian 2 (Parent of Bilal Ahmed - Class 8)
select gen_random_uuid() as g2_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'g2_user_id', 'parent8@circular.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'g2_user_id', :'tenant_id', 'parent', 'Zahid Ahmed');

select gen_random_uuid() as g2_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'g2_id', :'tenant_id'::uuid, :'g2_user_id'::uuid, 'Zahid Ahmed', '+923009990002');

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'s2_id'::uuid, :'g2_id'::uuid, 'father', true, true);

-- Create Dynamic Segment for Class 9 Pre-Medical
insert into public.message_segment (tenant_id, campus_id, name, segment_type, definition)
values (
  :'tenant_id'::uuid,
  :'campus_id'::uuid,
  'Class 9 Pre-Medical Segment',
  'class_level',
  jsonb_build_object(
    'class_level_id', :'class_9_id'::uuid,
    'section_id', :'sec_9_med_id'::uuid
  )
);
select id as seg_class_9_id from public.message_segment where name = 'Class 9 Pre-Medical Segment' and tenant_id = :'tenant_id'::uuid limit 1 \gset

-- ─── 2. Test AC 1: Attachment Size & Max Count Enforcement ─────────────────
select gen_random_uuid() as circ_1_id \gset
insert into public.circular (id, tenant_id, campus_id, title, body_en, body_ur, status)
values (:'circ_1_id', :'tenant_id'::uuid, :'campus_id'::uuid, 'Science Fair Circular', 'Please attend the fair.', 'سائنس فیئر میں شرکت فرمائیں', 'draft');

-- AC 1: Attachment larger than 10MB (10,485,761 bytes) must fail CHECK constraint
select throws_ok(
  format(
    'insert into public.circular_attachment (circular_id, storage_path, file_name, mime_type, size_bytes)
     values (%L, ''circulars/huge.pdf'', ''huge.pdf'', ''application/pdf'', 10485761)',
    :'circ_1_id'
  ),
  '23514',
  NULL,
  'AC 1: Attachment > 10MB rejected by check constraint'
);

-- Valid attachment (<= 10MB) succeeds
insert into public.circular_attachment (circular_id, storage_path, file_name, mime_type, size_bytes)
values (:'circ_1_id'::uuid, 'circulars/doc1.pdf', 'doc1.pdf', 'application/pdf', 1048576);

select is(
  (select count(*)::int from public.circular_attachment where circular_id = :'circ_1_id'::uuid),
  1,
  'AC 1: Valid 1MB attachment inserted successfully'
);

-- Insert 4 more attachments (total 5)
insert into public.circular_attachment (circular_id, storage_path, file_name, mime_type, size_bytes)
values
  (:'circ_1_id'::uuid, 'circulars/doc2.pdf', 'doc2.pdf', 'application/pdf', 500000),
  (:'circ_1_id'::uuid, 'circulars/doc3.pdf', 'doc3.pdf', 'application/pdf', 500000),
  (:'circ_1_id'::uuid, 'circulars/doc4.pdf', 'doc4.pdf', 'application/pdf', 500000),
  (:'circ_1_id'::uuid, 'circulars/doc5.pdf', 'doc5.pdf', 'application/pdf', 500000);

select is(
  (select count(*)::int from public.circular_attachment where circular_id = :'circ_1_id'::uuid),
  5,
  'AC 1: Circular can have exactly 5 attachments'
);

-- Attempting a 6th attachment must fail with limit error
select throws_ok(
  format(
    'insert into public.circular_attachment (circular_id, storage_path, file_name, mime_type, size_bytes)
     values (%L, ''circulars/doc6.pdf'', ''doc6.pdf'', ''application/pdf'', 100000)',
    :'circ_1_id'
  ),
  '23514',
  'MAX_ATTACHMENTS_EXCEEDED: A circular can have at most 5 attachments (current: 5)',
  'AC 1: 6th attachment rejected with MAX_ATTACHMENTS_EXCEEDED error'
);

-- ─── 3. Test AC 2: Scheduled publish_at hidden from portal UI & API ────────
select gen_random_uuid() as scheduled_circ_id \gset
insert into public.circular (id, tenant_id, campus_id, title, body_en, publish_at, status)
values (
  :'scheduled_circ_id',
  :'tenant_id'::uuid,
  :'campus_id'::uuid,
  'Future Fee Hike Notice',
  'Notice of revised fee structure.',
  now() + interval '1 day',
  'published'
);

-- Under Parent 1 auth context with authenticated role to enforce RLS:
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g1_user_id'
  )::text,
  true
);

-- Scheduled circular (tomorrow) MUST NOT be visible to parent via RLS
select is(
  (select count(*)::int from public.circular where id = :'scheduled_circ_id'::uuid),
  0,
  'AC 2: Future circular (publish_at > now) is absent from parent queries'
);

-- Switch back to admin and publish circular for now
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_id'
  )::text,
  true
);

update public.circular
set publish_at = now() - interval '1 hour'
where id = :'scheduled_circ_id'::uuid;

-- Switch to Parent 1 auth context:
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g1_user_id'
  )::text,
  true
);

select is(
  (select count(*)::int from public.circular where id = :'scheduled_circ_id'::uuid),
  1,
  'AC 2: Circular becomes visible to parent once publish_at <= now'
);

-- ─── 4. Test AC 3: Targeted audience segment isolation ─────────────────────
-- Create circular targeted specifically at Class 9 Pre-Medical
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_id'
  )::text,
  true
);

select gen_random_uuid() as class9_circ_id \gset
insert into public.circular (id, tenant_id, campus_id, title, body_en, publish_at, status)
values (
  :'class9_circ_id',
  :'tenant_id'::uuid,
  :'campus_id'::uuid,
  'Class 9 Biology Practical Instructions',
  'Please bring dissecting box on Monday.',
  now() - interval '5 minutes',
  'published'
);

insert into public.circular_audience (circular_id, segment_id)
values (:'class9_circ_id'::uuid, :'seg_class_9_id'::uuid);

-- Query as Parent 1 (Ali Khan in Class 9 Pre-Medical): MUST SEE IT
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g1_user_id'
  )::text,
  true
);

select is(
  (select count(*)::int from public.circular where id = :'class9_circ_id'::uuid),
  1,
  'AC 3: Class 9 Parent can query Class 9 targeted circular directly'
);

-- Query as Parent 2 (Bilal Ahmed in Class 8): MUST GET 0 ROWS (API 404)
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g2_user_id'
  )::text,
  true
);

select is(
  (select count(*)::int from public.circular where id = :'class9_circ_id'::uuid),
  0,
  'AC 3: Class 8 Parent querying Class 9 circular directly receives 0 rows via RLS'
);

-- ─── 5. Test AC 4: Unpublishing circular removes from feed, retains records ─
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_id'
  )::text,
  true
);

-- Admin unpublishes the circular
select public.unpublish_circular(:'class9_circ_id'::uuid);

select is(
  (select status from public.circular where id = :'class9_circ_id'::uuid),
  'unpublished',
  'AC 4: unpublish_circular updates circular status to unpublished'
);

-- Query as Parent 1 (Class 9 Parent): MUST NOW GET 0 ROWS
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g1_user_id'
  )::text,
  true
);

select is(
  (select count(*)::int from public.circular where id = :'class9_circ_id'::uuid),
  0,
  'AC 4: Unpublished circular is immediately absent from Parent 1 queries'
);

-- Check that attachments and audience metadata remain intact in database
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_id'
  )::text,
  true
);

select is(
  (select count(*)::int from public.circular_audience where circular_id = :'class9_circ_id'::uuid),
  1,
  'AC 4: Circular audience metadata is retained after unpublishing'
);

select is(
  (select count(*)::int from public.circular_attachment where circular_id = :'circ_1_id'::uuid),
  5,
  'AC 4: Circular attachments are retained after lifecycle changes'
);

select * from finish();
rollback;
