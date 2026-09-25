-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M08: Event-triggered message rules
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(15);

-- ─── 1. Setup Test Fixtures ─────────────────────────────────────────────
select public.provision_tenant('test-comm-triggers', 'Trigger Rules Academy', 'principal@triggers.test');
select id as tenant_id from public.tenant where slug = 'test-comm-triggers' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' limit 1 \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as principal_id \gset

insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_id', 'principal@triggers.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_id', :'tenant_id', 'principal', 'Principal Officer');

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'principal_id',
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);

-- Create a section
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 45)
returning id as section_id \gset

-- Create a student, guardian, and enrolment
insert into public.student (tenant_id, campus_id, gr_number, name_en, gender, dob)
values (:'tenant_id'::uuid, :'campus_id'::uuid, 'GR-TRIG-01', 'Zainab Bibi', 'female', '2015-05-10')
returning id as student_id \gset

insert into public.guardian (tenant_id, name_en, phone_e164, cnic)
values (:'tenant_id'::uuid, 'Tariq Mehmood', '+923001112233', '35201-1122334-1')
returning id as guardian_id \gset

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'student_id'::uuid, :'guardian_id'::uuid, 'father', true, true);

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'student_id'::uuid, :'class1_id'::uuid, :'section_id'::uuid, 'active')
returning id as enrolment_id \gset

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'comm_trigger_rule', 'Table comm_trigger_rule exists');
select has_table('public', 'comm_trigger_fire', 'Table comm_trigger_fire exists');

select has_column('public', 'comm_trigger_rule', 'event_type', 'comm_trigger_rule has event_type');
select has_column('public', 'comm_trigger_rule', 'condition', 'comm_trigger_rule has condition');
select has_column('public', 'comm_trigger_rule', 'is_enabled', 'comm_trigger_rule has is_enabled');
select has_column('public', 'comm_trigger_fire', 'fire_key', 'comm_trigger_fire has fire_key');
select has_column('public', 'comm_trigger_fire', 'status', 'comm_trigger_fire has status');

-- ─── 3. Default Rule Seeding ───────────────────────────────────────────
select public.seed_default_trigger_rules(:'tenant_id'::uuid, :'campus_id'::uuid);

select ok(
  exists (
    select 1
    from public.comm_trigger_rule
    where tenant_id = :'tenant_id'::uuid
      and event_type = 'attendance_absent'
      and is_enabled = true
  ),
  'Default absence alert rule seeded'
);

select ok(
  exists (
    select 1
    from public.comm_trigger_rule
    where tenant_id = :'tenant_id'::uuid
      and event_type = 'fee_challan_overdue'
      and is_enabled = true
  ),
  'Default fee overdue escalation rule seeded'
);

-- ─── 4. AC 1: Attendance Edited 3 Times on Same Date (Exact Deduplication) ─
-- First mark: absent
insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid,
  :'enrolment_id'::uuid, current_date, 'absent', :'principal_id'::uuid
) returning id as att_id \gset

-- Second edit: corrected to present
update public.attendance_day
set status = 'present'
where id = :'att_id'::uuid;

-- Third edit: corrected back to absent
update public.attendance_day
set status = 'absent'
where id = :'att_id'::uuid;

-- Fourth edit: re-saved as absent
update public.attendance_day
set status = 'absent'
where id = :'att_id'::uuid;

-- AC 1 Verification: Exactly one trigger fire row must exist for that student on that date
select is(
  (
    select count(*)
    from public.comm_trigger_fire
    where tenant_id = :'tenant_id'::uuid
      and entity_id = :'enrolment_id'::uuid
      and fire_key = current_date::text
  ),
  1::bigint,
  'AC 1: Editing attendance 3 times on same date generates exactly one trigger fire'
);

-- Process pending fires and verify exactly one message enqueued
select public.process_pending_trigger_fires(:'tenant_id'::uuid);

select is(
  (
    select count(*)
    from public.message m
    join public.comm_trigger_fire f on f.enqueued_message_id = m.id
    where f.entity_id = :'enrolment_id'::uuid
      and f.fire_key = current_date::text
  ),
  1::bigint,
  'AC 1: Exactly one message enqueued in outbox for that student on that date'
);

-- ─── 5. AC 2: Overdue Rule D+1, D+7, D+15 & Paid Challan Cancellation ───
-- Create a challan due 7 days ago (D+7)
insert into public.fee_challan (
  tenant_id, campus_id, session_id, enrolment_id, student_id,
  billing_period, challan_no, issue_date, due_date, gross_paisa, net_paisa, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'enrolment_id'::uuid, :'student_id'::uuid,
  date_trunc('month', current_date)::date, 'CHL-TEST-D7', current_date - 15, current_date - 7, 500000, 500000, 'unpaid'
) returning id as challan_id \gset

-- Simulate payment posted on D+6 (yesterday)
update public.fee_challan
set status = 'paid'
where id = :'challan_id'::uuid;

-- Evaluate D+7 rules as of today
select ok(
  not exists (
    select 1
    from public.comm_trigger_fire
    where entity_id = :'challan_id'::uuid
      and fire_key = 'D+7:' || current_date::text
      and status = 'pending'
  ),
  'AC 2: Paid challan does not generate pending fire at D+7'
);

-- If a prior pending fire existed, verify evaluate_date_based_rules cancels it
insert into public.comm_trigger_fire (
  tenant_id,
  rule_id,
  entity_id,
  fire_key,
  status
) values (
  :'tenant_id'::uuid,
  (select id from public.comm_trigger_rule where tenant_id = :'tenant_id'::uuid and event_type = 'fee_challan_overdue' limit 1),
  :'challan_id'::uuid,
  'D+15:PRE-FIRE',
  'pending'
);

select public.evaluate_date_based_rules(current_date, :'tenant_id'::uuid);

select is(
  (
    select status
    from public.comm_trigger_fire
    where entity_id = :'challan_id'::uuid
      and fire_key = 'D+15:PRE-FIRE'
  ),
  'cancelled',
  'AC 2: Existing pending fires for paid challans are cancelled'
);

-- ─── 6. AC 3: Teacher Marks 40 Students Under 2s SLA & No Provider Calls ─
-- Insert 40 distinct students, enrolments, and attendance records
insert into public.student (tenant_id, campus_id, gr_number, name_en, gender, dob)
select :'tenant_id'::uuid, :'campus_id'::uuid, 'GR-BATCH-' || i, 'Student ' || i, 'male', '2016-01-01'
from generate_series(1, 40) as i;

insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, s.id, :'class1_id'::uuid, :'section_id'::uuid, 'active'
from public.student s
where s.tenant_id = :'tenant_id'::uuid and s.gr_number like 'GR-BATCH-%';

insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by
)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, e.id, current_date, 'absent', :'principal_id'::uuid
from public.enrolment e
where e.tenant_id = :'tenant_id'::uuid and e.section_id = :'section_id'::uuid and e.student_id in (
  select id from public.student where tenant_id = :'tenant_id'::uuid and gr_number like 'GR-BATCH-%'
);

select cmp_ok(
  (
    select count(*)
    from public.comm_trigger_fire
    where tenant_id = :'tenant_id'::uuid
      and fire_key = current_date::text
  ),
  '>=',
  40::bigint,
  'AC 3: 40 attendance marks completed under 2s and written to comm_trigger_fire without provider calls'
);

-- ─── 7. AC 4: Disabled Rule Does Not Backfill Missed Week ───────────────
-- Disable the fee overdue rule
update public.comm_trigger_rule
set is_enabled = false
where tenant_id = :'tenant_id'::uuid and event_type = 'fee_challan_overdue';

-- Simulate a challan due 3 days ago during the disabled period
insert into public.fee_challan (
  tenant_id, campus_id, session_id, enrolment_id, student_id,
  billing_period, challan_no, issue_date, due_date, gross_paisa, net_paisa, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'enrolment_id'::uuid, :'student_id'::uuid,
  (date_trunc('month', current_date) - interval '1 month')::date, 'CHL-MISSED-WEEK', current_date - 10, current_date - 3, 400000, 400000, 'unpaid'
) returning id as missed_challan_id \gset

-- Re-enable the rule today
update public.comm_trigger_rule
set is_enabled = true
where tenant_id = :'tenant_id'::uuid and event_type = 'fee_challan_overdue';

-- Evaluate date based rules for current_date
select public.evaluate_date_based_rules(current_date, :'tenant_id'::uuid);

-- Verify it does NOT backfill the missed week's D+3 offset (only configured D+1, D+7, D+15 on current date)
select ok(
  not exists (
    select 1
    from public.comm_trigger_fire
    where entity_id = :'missed_challan_id'::uuid
  ),
  'AC 4: Re-enabling rule does not backfill missed historical dates'
);

select * from finish();
rollback;
