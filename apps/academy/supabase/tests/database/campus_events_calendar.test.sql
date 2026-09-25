-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M14: Campus events calendar
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(13);

-- ─── 1. Setup Test Fixtures (as postgres) ──────────────────────────────────
select public.provision_tenant('test-campus-cal', 'Calendar Academy', 'owner@calendar.test');
select id as tenant_id from public.tenant where slug = 'test-campus-cal' \gset

-- 4 campuses for tenant (AC 2 test requirement)
select id as campus_1_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

insert into public.campus (tenant_id, name, code)
values (:'tenant_id', 'Campus Two', 'C2')
returning id as campus_2_id \gset

insert into public.campus (tenant_id, name, code)
values (:'tenant_id', 'Campus Three', 'C3')
returning id as campus_3_id \gset

insert into public.campus (tenant_id, name, code)
values (:'tenant_id', 'Campus Four', 'C4')
returning id as campus_4_id \gset

-- Admin User
select gen_random_uuid() as admin_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_id', 'admin@calendar.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_id', :'tenant_id', 'owner', 'Director Vance');

-- Switch to admin auth context
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_1_id', :'campus_2_id', :'campus_3_id', :'campus_4_id'),
    'sub', :'admin_id'
  )::text,
  true
);

-- Academic session and class levels
select id as session_id from public.academic_session where tenant_id = :'tenant_id'::uuid limit 1 \gset
select id as class_9_id from public.class_level where tenant_id = :'tenant_id'::uuid and name_en = 'Class 9' limit 1 \gset
select public.create_section(:'campus_1_id'::uuid, :'session_id'::uuid, :'class_9_id'::uuid, 'Section-A', 40) as sec_1_id \gset

-- Create Student in Campus 1
select public.create_student(:'campus_1_id'::uuid, 'Zainab Bibi', '2010-06-01'::date, 'female') as s1_id \gset
select public.enrol_student(:'sec_1_id'::uuid, :'s1_id'::uuid) as enrol_1_id \gset

-- Guardian for Zainab (Campus 1)
select gen_random_uuid() as g1_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'g1_user_id', 'parent_cal@calendar.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'g1_user_id', :'tenant_id', 'parent', 'Rashid Bibi');

select gen_random_uuid() as g1_id \gset
insert into public.guardian (id, tenant_id, auth_user_id, name_en, phone_e164)
values (:'g1_id', :'tenant_id', :'g1_user_id', 'Rashid Bibi', '+923005555555');

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'s1_id', :'g1_id', 'father', true, true);

-- Enable FR-M08 Trigger Rule for Student Absence
insert into public.comm_trigger_rule (
  tenant_id, campus_id, name, event_type, channel, is_enabled
)
values (
  :'tenant_id', :'campus_1_id', 'Absence Alert Rule', 'attendance_absent', 'sms', true
)
returning id as rule_id \gset

-- ─── AC 1: Campus Holiday Suppresses FR-M08 Absence Messages ───────────────────
-- Mark 2026-10-15 (Thursday) as a Holiday for Campus 1
insert into public.campus_event (
  tenant_id, campus_id, title, event_type, starts_at, ends_at, is_all_day, hijri_label
)
values (
  :'tenant_id',
  :'campus_1_id',
  'Iqbal Day Holiday',
  'holiday',
  '2026-10-15 00:00:00+00'::timestamptz,
  '2026-10-15 23:59:59+00'::timestamptz,
  true,
  'Public Holiday'
)
returning id as holiday_event_id \gset

-- Verify is_working_day returns false on the holiday
select is(
  public.is_working_day(:'campus_1_id'::uuid, '2026-10-15'::date),
  false,
  'AC 1: is_working_day returns false for a marked campus holiday'
);

-- Verify is_working_day returns true on the next regular working day (2026-10-16 Friday)
select is(
  public.is_working_day(:'campus_1_id'::uuid, '2026-10-16'::date),
  true,
  'AC 1: is_working_day returns true for a normal non-holiday working day'
);

-- Record absence on the holiday (2026-10-15)
insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status
)
values (
  :'tenant_id', :'campus_1_id', :'session_id', :'sec_1_id', :'enrol_1_id', '2026-10-15'::date, 'absent'
);

-- Check comm_trigger_fire: Should be 0 rows because the date is a holiday!
select is(
  (select count(*)::integer from public.comm_trigger_fire where rule_id = :'rule_id' and fire_key = '2026-10-15'),
  0,
  'AC 1: Daily attendance trigger of FR-M08 suppresses absence messages on a campus holiday'
);

-- Now record absence on the regular working day (2026-10-16)
insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status
)
values (
  :'tenant_id', :'campus_1_id', :'session_id', :'sec_1_id', :'enrol_1_id', '2026-10-16'::date, 'absent'
);

-- Check comm_trigger_fire: Should have 1 row for 2026-10-16!
select is(
  (select count(*)::integer from public.comm_trigger_fire where rule_id = :'rule_id' and fire_key = '2026-10-16'),
  1,
  'AC 1: Daily attendance trigger fires normally on a working day'
);

-- ─── AC 2: Tenant-level Event Across 4 Campuses with 1 Campus Override ────────
-- Create Tenant-level event (campus_id is null) across all 4 campuses
insert into public.campus_event (
  tenant_id, campus_id, title, description, event_type, starts_at, ends_at, is_all_day
)
values (
  :'tenant_id',
  null,
  'Midterm Exam Week',
  'Centralized examinations across all campuses.',
  'exam',
  '2026-11-10 09:00:00+00'::timestamptz,
  '2026-11-15 17:00:00+00'::timestamptz,
  true
)
returning id as tenant_exam_id \gset

-- Campus 1 overrides it: rescheduled to 2026-11-12
insert into public.campus_event_override (
  event_id, campus_id, override_type, title, starts_at, ends_at, reason
)
values (
  :'tenant_exam_id',
  :'campus_1_id',
  'rescheduled',
  'Campus 1 Rescheduled Midterms',
  '2026-11-12 09:00:00+00'::timestamptz,
  '2026-11-17 17:00:00+00'::timestamptz,
  'Local sports conflict'
);

-- Verify Campus 1 has the overridden start date and title
select is(
  (select starts_at from public.v_effective_campus_events where event_id = :'tenant_exam_id' and campus_id = :'campus_1_id'),
  '2026-11-12 09:00:00+00'::timestamptz,
  'AC 2: Campus 1 override applies with rescheduled start date'
);

select is(
  (select title from public.v_effective_campus_events where event_id = :'tenant_exam_id' and campus_id = :'campus_1_id'),
  'Campus 1 Rescheduled Midterms',
  'AC 2: Campus 1 override title applies to Campus 1'
);

-- Verify the other 3 campuses (Campus 2, Campus 3, Campus 4) retain the tenant-level start date and title
select is(
  (select count(*)::integer from public.v_effective_campus_events
   where event_id = :'tenant_exam_id'
     and campus_id in (:'campus_2_id', :'campus_3_id', :'campus_4_id')
     and starts_at = '2026-11-10 09:00:00+00'::timestamptz
     and title = 'Midterm Exam Week'
     and not is_override),
  3,
  'AC 2: Other 3 campuses retain the original tenant-level entry without modification'
);

-- ─── AC 3: Guardian .ics Feed Token Scoped to Active Campuses & 401 on Revoke ──
-- Generate token for Guardian 1 (active child only in Campus 1)
select public.generate_guardian_ics_token(:'g1_id'::uuid) as g1_token \gset

select ok(
  :'g1_token' is not null and length(:'g1_token') >= 32,
  'AC 3: Successfully generated secure hex feed token for guardian'
);

-- Fetch events for Guardian 1 token: should contain events for Campus 1
select ok(
  exists (
    select 1 from public.get_guardian_ics_events(:'g1_token')
    where campus_id = :'campus_1_id'
  ),
  'AC 3: Guardian feed contains events for campus where guardian has active child (Campus 1)'
);

-- Verify feed contains NO events for other campuses (e.g. Campus 2)
select is(
  (select count(*)::integer from public.get_guardian_ics_events(:'g1_token') where campus_id = :'campus_2_id'),
  0,
  'AC 3: Guardian feed strictly excludes events for campuses where guardian has no active child'
);

-- Revoke the token
select public.revoke_guardian_ics_token(:'g1_token') as is_revoked \gset

select is(
  :'is_revoked'::boolean,
  true,
  'AC 3: Token is successfully marked as revoked'
);

-- Querying with revoked token raises error 42501 (mapped to 401 in Route Handler)
select throws_ok(
  format('select * from public.get_guardian_ics_events(%L)', :'g1_token'),
  '42501',
  'UNAUTHORIZED: Invalid or revoked feed token',
  'AC 3: Fetching feed with revoked token raises 42501 Unauthorized error'
);

-- ─── AC 4: Retroactive Past Holiday Does Not Silently Change Past Records ────
-- Insert a retroactive holiday for a past date (e.g. 5 days ago)
select (current_date - 5) as past_date \gset

insert into public.campus_event (
  tenant_id, campus_id, title, event_type, starts_at, ends_at, is_all_day
)
values (
  :'tenant_id',
  :'campus_1_id',
  'Past Unscheduled Holiday',
  'holiday',
  (:'past_date'::text || ' 00:00:00+00')::timestamptz,
  (:'past_date'::text || ' 23:59:59+00')::timestamptz,
  true
)
returning id as past_event_id \gset

-- Verify explicit recompute action is available and returns audited json summary
select ok(
  (public.recompute_past_holiday_impact(:'past_event_id'::uuid)->>'recomputed')::boolean,
  'AC 4: Explicit recompute action is available for retroactive holiday impact'
);

rollback;
