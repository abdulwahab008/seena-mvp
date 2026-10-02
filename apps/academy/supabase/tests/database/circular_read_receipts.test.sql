-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M13: Circular read receipts
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(12);

-- ─── 1. Setup Test Fixtures (as postgres) ──────────────────────────────────
select public.provision_tenant('test-circular-rr', 'Receipts Academy', 'owner@receipts.test');
select id as tenant_id from public.tenant where slug = 'test-circular-rr' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

-- Admin / Principal User
select gen_random_uuid() as admin_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_id', 'principal@receipts.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_id', :'tenant_id', 'owner', 'Principal Vernon');

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

-- Academic session and class levels
select id as session_id from public.academic_session where tenant_id = :'tenant_id'::uuid limit 1 \gset
select id as class_9_id from public.class_level where tenant_id = :'tenant_id'::uuid and name_en = 'Class 9' limit 1 \gset
select id as class_8_id from public.class_level where tenant_id = :'tenant_id'::uuid and name_en = 'Class 8' limit 1 \gset

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class_9_id'::uuid, 'Class-9A', 40) as sec_9_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class_8_id'::uuid, 'Class-8A', 40) as sec_8_id \gset

-- Guardian A (Parent with 1 child in Class 9)
select gen_random_uuid() as ga_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ga_user_id', 'guardiana@receipts.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ga_user_id', :'tenant_id', 'parent', 'Guardian Alpha');

select gen_random_uuid() as ga_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'ga_id', :'tenant_id', :'ga_user_id', 'Guardian Alpha', '+923001111111');

select public.create_student(:'campus_id'::uuid, 'Child Alpha 1', '2010-01-01'::date, 'male') as sa1_id \gset
select public.enrol_student(:'sec_9_id'::uuid, :'sa1_id'::uuid) as enrol_a1 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'sa1_id', :'ga_id', 'father', true, true);

-- Guardian B (Parent with 1 child in Class 9)
select gen_random_uuid() as gb_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'gb_user_id', 'guardianb@receipts.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'gb_user_id', :'tenant_id', 'parent', 'Guardian Beta');

select gen_random_uuid() as gb_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'gb_id', :'tenant_id', :'gb_user_id', 'Guardian Beta', '+923002222222');

select public.create_student(:'campus_id'::uuid, 'Child Beta 1', '2010-02-02'::date, 'female') as sb1_id \gset
select public.enrol_student(:'sec_9_id'::uuid, :'sb1_id'::uuid) as enrol_b1 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'sb1_id', :'gb_id', 'mother', true, true);

-- Guardian Multi (Parent with 3 children, ALL in target Class 9) -> Tests AC 3
select gen_random_uuid() as g_multi_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'g_multi_user_id', 'guardianmulti@receipts.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'g_multi_user_id', :'tenant_id', 'parent', 'Guardian Multi');

select gen_random_uuid() as g_multi_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'g_multi_id', :'tenant_id', :'g_multi_user_id', 'Guardian Multi', '+923003333333');

-- 3 children for Guardian Multi in Class 9
select public.create_student(:'campus_id'::uuid, 'Child Multi 1', '2010-03-01'::date, 'male') as sm1_id \gset
select public.enrol_student(:'sec_9_id'::uuid, :'sm1_id'::uuid) as enrol_m1 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'sm1_id', :'g_multi_id', 'father', true, true);

select public.create_student(:'campus_id'::uuid, 'Child Multi 2', '2010-03-02'::date, 'female') as sm2_id \gset
select public.enrol_student(:'sec_9_id'::uuid, :'sm2_id'::uuid) as enrol_m2 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'sm2_id', :'g_multi_id', 'father', true, true);

select public.create_student(:'campus_id'::uuid, 'Child Multi 3', '2010-03-03'::date, 'male') as sm3_id \gset
select public.enrol_student(:'sec_9_id'::uuid, :'sm3_id'::uuid) as enrol_m3 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'sm3_id', :'g_multi_id', 'father', true, true);

-- Guardian Outside (Child in Class 8, not targeted)
select gen_random_uuid() as g_out_id \gset
insert into public.guardian (id, tenant_id, name_en, phone_e164)
values (:'g_out_id', :'tenant_id', 'Guardian Outside', '+923004444444');

select public.create_student(:'campus_id'::uuid, 'Child Out', '2011-04-04'::date, 'male') as so_id \gset
select public.enrol_student(:'sec_8_id'::uuid, :'so_id'::uuid) as enrol_out \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'so_id', :'g_out_id', 'father', true, true);

-- Create Target Audience Segment for Class 9
insert into public.message_segment (
  tenant_id, campus_id, name, segment_type, definition
)
values (
  :'tenant_id',
  :'campus_id',
  'Target Class 9 Audience',
  'class_level',
  jsonb_build_object('class_level_id', :'class_9_id')
)
returning id as target_seg_id \gset

-- Create Circular
insert into public.circular (
  tenant_id, campus_id, title, body_en, status, publish_at, created_by
)
values (
  :'tenant_id',
  :'campus_id',
  'Annual Sports Day Announcement',
  'Sports day will be held on Friday.',
  'published',
  now() - interval '1 hour',
  :'admin_id'
)
returning id as circ_id \gset

-- Link Circular Audience to Class 9 Segment
insert into public.circular_audience (circular_id, segment_id)
values (:'circ_id', :'target_seg_id');

-- ─── AC 1: Duplicate Opens Preserve 1 Row and first_read_at ─────────────────
-- Step 1: Guardian Alpha opens circular 1st time
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'ga_user_id'
  )::text,
  true
);

select public.mark_circular_read(:'circ_id'::uuid, :'ga_id'::uuid);
select first_read_at as t1_read_at from public.circular_read_receipt where circular_id = :'circ_id' and guardian_id = :'ga_id' \gset

-- Step 2: Guardian Alpha opens 2nd time
select public.mark_circular_read(:'circ_id'::uuid, :'ga_id'::uuid);

-- Step 3: Guardian Alpha opens 3rd time
select public.mark_circular_read(:'circ_id'::uuid, :'ga_id'::uuid);

-- Verify exactly 1 row exists
select is(
  (select count(*)::integer from public.circular_read_receipt where circular_id = :'circ_id' and guardian_id = :'ga_id'),
  1,
  'AC 1: Opening circular three times creates exactly one row'
);

-- Verify first_read_at is unchanged
select is(
  (select first_read_at from public.circular_read_receipt where circular_id = :'circ_id' and guardian_id = :'ga_id'),
  :'t1_read_at'::timestamptz,
  'AC 1: first_read_at is strictly preserved from the first open'
);

-- ─── AC 3: Guardian with 3 children is counted ONCE in stats ─────────────────
-- Switch back to admin context to inspect stats view
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

-- The target segment includes Class 9: Guardian Alpha (1 child), Guardian Beta (1 child), Guardian Multi (3 children).
-- Total distinct targeted guardians must be exactly 3 (Guardian Alpha, Guardian Beta, Guardian Multi).
-- Not 5 (even though there are 5 enrolled children across the 3 guardians).
select is(
  (select total_targeted_guardians::integer from public.v_circular_read_stats where circular_id = :'circ_id'),
  3,
  'AC 3: Guardian with 3 children in target segment is counted once in targeted total (3 guardians total)'
);

-- Now Guardian Multi opens the circular
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'g_multi_user_id'
  )::text,
  true
);
select public.mark_circular_read(:'circ_id'::uuid, :'g_multi_id'::uuid);

-- Check stats again
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

-- Now 2 out of 3 have read (Guardian Alpha and Guardian Multi)
select is(
  (select read_guardians_count::integer from public.v_circular_read_stats where circular_id = :'circ_id'),
  2,
  'AC 3: Guardian Multi opening the circular counts as 1 read guardian (2 of 3 read)'
);

-- ─── AC 2: Stats Display and Export Unread Segment for FR-M06 ─────────────────
select is(
  (select formatted_stats from public.v_circular_read_stats where circular_id = :'circ_id'),
  '2 of 3 read (67%)',
  'AC 2: Stats display shows formatted "X of Y read (Z%)"'
);

select is(
  (select unread_guardians_count::integer from public.v_circular_read_stats where circular_id = :'circ_id'),
  1,
  'AC 2: Unread count shows remaining unread guardians (1 unread)'
);

-- Check v_circular_unread_guardians view has Guardian Beta (+923002222222)
select is(
  (select phone_e164 from public.v_circular_unread_guardians where circular_id = :'circ_id'),
  '+923002222222',
  'AC 2: Unread view contains the unread guardian with phone number'
);

-- Test Export unread segment function
select public.export_circular_unread_segment(:'circ_id'::uuid, 'Sports Day Unread Follow-up') as unread_seg_id \gset

select ok(
  :'unread_seg_id' is not null,
  'AC 2: Export unread segment successfully generates a message_segment'
);

-- Resolve exported segment to verify FR-M06 follow-up
select is(
  (select count(*)::integer from public.resolve_segment(:'unread_seg_id'::uuid)),
  1,
  'AC 2: Resolving exported unread segment yields exactly the unread guardian follow-up'
);

select is(
  (select guardian_phone from public.resolve_segment(:'unread_seg_id'::uuid)),
  '+923002222222',
  'AC 2: Exported segment resolves unread guardian phone number for campaign dispatch'
);

-- ─── AC 4: RLS Prevents Guardian A from Seeing Guardian B''s Receipts ────────
-- Both Guardian Alpha and Guardian Beta now have receipts
select public.mark_circular_read(:'circ_id'::uuid, :'gb_id'::uuid);

-- Switch auth context to Guardian Alpha
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'parent',
    'sub', :'ga_user_id'
  )::text,
  true
);
set role authenticated;

-- Guardian Alpha queries all receipts for the circular
select is(
  (select count(*)::integer from public.circular_read_receipt where circular_id = :'circ_id'),
  1,
  'AC 4: Guardian Alpha querying circular receipts only sees 1 receipt (their own)'
);

-- Guardian Alpha attempts to query Guardian Beta's receipt directly
select is(
  (select count(*)::integer from public.circular_read_receipt where circular_id = :'circ_id' and guardian_id = :'gb_id'),
  0,
  'AC 4: RLS hides Guardian Beta receipt from Guardian Alpha (0 rows returned)'
);

rollback;
