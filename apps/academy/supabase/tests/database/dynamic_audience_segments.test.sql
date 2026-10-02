-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M06: Dynamic audience segments
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(18);

-- ─── 1. Setup Test Fixtures ─────────────────────────────────────────────
select public.provision_tenant('test-dyn-segments', 'Dynamic Segments Academy', 'owner@segments.test');
select id as tenant_id from public.tenant where slug = 'test-dyn-segments' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' limit 1 \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30)
returning id as section_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'message_segment', 'Table message_segment exists');
select has_table('public', 'message_audience_snapshot', 'Table message_audience_snapshot exists');
select has_column('public', 'campus', 'attendance_lock_cutoff', 'campus has attendance_lock_cutoff column');
select has_column('public', 'message_segment', 'segment_type', 'message_segment has segment_type column');
select has_column('public', 'message_segment', 'definition', 'message_segment has definition column');
select has_column('public', 'message_audience_snapshot', 'campaign_id', 'message_audience_snapshot has campaign_id column');

-- ─── 3. Default Seed Segments Check ─────────────────────────────────────
select public.seed_default_segments(:'tenant_id'::uuid, :'campus_id'::uuid);

select ok(
  exists (
    select 1
    from public.message_segment
    where tenant_id = :'tenant_id'::uuid
      and campus_id = :'campus_id'::uuid
      and name = 'Fee Defaulters (> PKR 5,000)'
  ),
  'Default Fee Defaulters segment was seeded'
);

select ok(
  exists (
    select 1
    from public.message_segment
    where tenant_id = :'tenant_id'::uuid
      and campus_id = :'campus_id'::uuid
      and name = 'Unexcused Absentees Today'
  ),
  'Default Absent Today segment was seeded'
);

-- ─── 4. AC 1: Defaulters Segment & Hardship Waiver Exclusion ───────────
-- Student 1: Owes 7,500 PKR (no waiver) -> SHOULD BE TARGETED
insert into public.student (
  tenant_id, campus_id, gr_number, name_en, dob, gender, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'GR-SEG-01', 'Ali Defaulter', '2015-05-15', 'male', 'active'
) returning id as student_1_id \gset

insert into public.enrolment (
  tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'student_1_id'::uuid, :'class1_id'::uuid, :'section_id'::uuid, 'active'
) returning id as enrolment_1_id \gset

insert into public.guardian (
  tenant_id, name_en, phone_e164
) values (
  :'tenant_id'::uuid, 'Parent of Ali', '+923001112233'
) returning id as guardian_1_id \gset

insert into public.student_guardian (
  tenant_id, student_id, guardian_id, is_primary, receives_billing, relationship
) values (
  :'tenant_id'::uuid, :'student_1_id'::uuid, :'guardian_1_id'::uuid, true, true, 'father'
);

-- Create outstanding unpaid fee challan: 7,500 PKR = 750,000 paisa
insert into public.fee_challan (
  tenant_id, campus_id, enrolment_id, student_id, session_id,
  billing_period, challan_no, issue_date, due_date,
  gross_paisa, net_paisa, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrolment_1_id'::uuid, :'student_1_id'::uuid, :'session_id'::uuid,
  current_date, 'CH-001', current_date - 10, current_date - 5,
  750000, 750000, 'unpaid'
) returning id as challan_1_id \gset

insert into public.fee_ledger (
  tenant_id, campus_id, enrolment_id, session_id, challan_id, entry_type, amount_paisa, direction
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrolment_1_id'::uuid, :'session_id'::uuid, :'challan_1_id'::uuid, 'charge', 750000, 'debit'
);

-- Student 2: Owes 8,000 PKR but carries an APPROVED Hardship Waiver -> MUST BE EXCLUDED
insert into public.student (
  tenant_id, campus_id, gr_number, name_en, dob, gender, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'GR-SEG-02', 'Bilal Hardship', '2015-06-15', 'male', 'active'
) returning id as student_2_id \gset

insert into public.enrolment (
  tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'student_2_id'::uuid, :'class1_id'::uuid, :'section_id'::uuid, 'active'
) returning id as enrolment_2_id \gset

insert into public.guardian (
  tenant_id, name_en, phone_e164
) values (
  :'tenant_id'::uuid, 'Parent of Bilal', '+923002223344'
) returning id as guardian_2_id \gset

insert into public.student_guardian (
  tenant_id, student_id, guardian_id, is_primary, receives_billing, relationship
) values (
  :'tenant_id'::uuid, :'student_2_id'::uuid, :'guardian_2_id'::uuid, true, true, 'father'
);

insert into public.fee_challan (
  tenant_id, campus_id, enrolment_id, student_id, session_id,
  billing_period, challan_no, issue_date, due_date,
  gross_paisa, net_paisa, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrolment_2_id'::uuid, :'student_2_id'::uuid, :'session_id'::uuid,
  current_date, 'CH-002', current_date - 10, current_date - 5,
  800000, 800000, 'unpaid'
) returning id as challan_2_id \gset

insert into public.fee_ledger (
  tenant_id, campus_id, enrolment_id, session_id, challan_id, entry_type, amount_paisa, direction
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrolment_2_id'::uuid, :'session_id'::uuid, :'challan_2_id'::uuid, 'charge', 800000, 'debit'
);

insert into public.concession_scheme (
  tenant_id, code, name_en, name_ur, category, calc_type, value, applicable_head_ids
) values (
  :'tenant_id'::uuid, 'HARDSHIP_FEE_AID', 'Hardship Financial Aid', 'مالی امداد', 'hardship', 'fixed_amount', 800000, array[:'tuition_id'::uuid]
) returning id as hardship_scheme_id \gset

insert into public.concession_award (
  tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value,
  status, effective_from, effective_to
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'enrolment_2_id'::uuid, :'hardship_scheme_id'::uuid,
  'fixed_amount', 800000, 'approved', current_date - 30, current_date + 30
);

-- Fetch defaulters segment ID
select id as defaulter_seg_id
from public.message_segment
where tenant_id = :'tenant_id'::uuid and campus_id = :'campus_id'::uuid and segment_type = 'defaulters'
limit 1 \gset

-- Test AC 1: Ali is included
select ok(
  exists (
    select 1
    from public.resolve_segment(:'defaulter_seg_id'::uuid, current_date)
    where student_id = :'student_1_id'::uuid
  ),
  'FR-M06 AC 1a: Student with dues > PKR 5,000 without waiver is included in segment'
);

-- Test AC 1: Bilal with approved hardship waiver is EXCLUDED
select ok(
  not exists (
    select 1
    from public.resolve_segment(:'defaulter_seg_id'::uuid, current_date)
    where student_id = :'student_2_id'::uuid
  ),
  'FR-M06 AC 1b: Student with approved hardship waiver is excluded from defaulters segment'
);

-- ─── 5. AC 2: Attendance Cutoff & Correction from Absent to Present ────
-- Student 3: Marked Absent today -> TARGETED
insert into public.student (
  tenant_id, campus_id, gr_number, name_en, dob, gender, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'GR-SEG-03', 'Chaudhry Absent', '2015-07-15', 'male', 'active'
) returning id as student_3_id \gset

insert into public.enrolment (
  tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'student_3_id'::uuid, :'class1_id'::uuid, :'section_id'::uuid, 'active'
) returning id as enrolment_3_id \gset

insert into public.guardian (
  tenant_id, name_en, phone_e164
) values (
  :'tenant_id'::uuid, 'Parent of Chaudhry', '+923003334455'
) returning id as guardian_3_id \gset

insert into public.student_guardian (
  tenant_id, student_id, guardian_id, is_primary, receives_academic, receives_billing, relationship
) values (
  :'tenant_id'::uuid, :'student_3_id'::uuid, :'guardian_3_id'::uuid, true, true, true, 'father'
);

insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, corrected
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrolment_3_id'::uuid,
  current_date, 'absent', false
);

-- Student 4: Marked Absent early, but corrected from Absent to Present at 10:40 -> MUST NOT BE MESSAGED
insert into public.student (
  tenant_id, campus_id, gr_number, name_en, dob, gender, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'GR-SEG-04', 'Danyal Corrected', '2015-08-15', 'male', 'active'
) returning id as student_4_id \gset

insert into public.enrolment (
  tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'student_4_id'::uuid, :'class1_id'::uuid, :'section_id'::uuid, 'active'
) returning id as enrolment_4_id \gset

insert into public.guardian (
  tenant_id, name_en, phone_e164
) values (
  :'tenant_id'::uuid, 'Parent of Danyal', '+923004445566'
) returning id as guardian_4_id \gset

insert into public.student_guardian (
  tenant_id, student_id, guardian_id, is_primary, receives_academic, receives_billing, relationship
) values (
  :'tenant_id'::uuid, :'student_4_id'::uuid, :'guardian_4_id'::uuid, true, true, true, 'father'
);

-- Teacher corrected Danyal to Present at 10:40
insert into public.attendance_day (
  tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, corrected
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_id'::uuid, :'enrolment_4_id'::uuid,
  current_date, 'present', true
);

-- Fetch absentee segment ID
select id as absentee_seg_id
from public.message_segment
where tenant_id = :'tenant_id'::uuid and campus_id = :'campus_id'::uuid and segment_type = 'absent_today'
limit 1 \gset

-- Test AC 2: Student 3 (Absent) is targeted
select ok(
  exists (
    select 1
    from public.resolve_segment(:'absentee_seg_id'::uuid, current_date)
    where student_id = :'student_3_id'::uuid
  ),
  'FR-M06 AC 2a: Student currently marked Absent is resolved in absent-today segment'
);

-- Test AC 2: Student 4 (corrected from Absent to Present) is NOT targeted
select ok(
  not exists (
    select 1
    from public.resolve_segment(:'absentee_seg_id'::uuid, current_date)
    where student_id = :'student_4_id'::uuid
  ),
  'FR-M06 AC 2b: Student corrected to Present before cutoff is NOT resolved/messaged'
);

-- ─── 6. AC 3: Zero-Recipient Warning & Guard ────────────────────────────
-- Create a segment with impossibly high dues (> PKR 100,000,000) that resolves to 0
insert into public.message_segment (
  tenant_id, campus_id, name, segment_type, definition
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'Impossible High Dues',
  'defaulters', '{"min_dues_pkr": 100000000, "exclude_hardship": false}'::jsonb
) returning id as zero_seg_id \gset

select is(
  (select count(*) from public.resolve_segment(:'zero_seg_id'::uuid, current_date)),
  0::bigint,
  'Segment criteria correctly resolves to 0 recipients'
);

-- AC 3: snapshot_campaign_audience must throw 22023 when 0 recipients
select throws_matching(
  format('select public.snapshot_campaign_audience(%L, %L)', gen_random_uuid(), :'zero_seg_id'),
  'Cannot dispatch campaign: dynamic segment "Impossible High Dues" resolved to 0 recipients.',
  'FR-M06 AC 3: Attempting to send to a zero-recipient segment is blocked with explicit warning'
);

-- ─── 7. AC 4: Point-in-Time Audience Audit Snapshot ────────────────────
-- Dispatch campaign to Defaulters segment and snapshot audience
select gen_random_uuid() as campaign_audit_id \gset

select lives_ok(
  format('select public.snapshot_campaign_audience(%L, %L)', :'campaign_audit_id', :'defaulter_seg_id'),
  'Campaign audience successfully snapshotted at dispatch time'
);

-- Verify snapshot record exists for Student 1
select ok(
  exists (
    select 1
    from public.message_audience_snapshot
    where campaign_id = :'campaign_audit_id'::uuid
      and student_id = :'student_1_id'::uuid
      and recipient_phone = '+923001112233'
  ),
  'FR-M06 AC 4a: Snapshot contains targeted student at dispatch time'
);

-- Now simulate Student 1 transferring out / withdrawing next week
update public.student
set status = 'transferred'
where id = :'student_1_id'::uuid;

update public.enrolment
set status = 'transferred'
where id = :'enrolment_1_id'::uuid;

-- Dynamic resolution TODAY no longer includes transferred student
select ok(
  not exists (
    select 1
    from public.resolve_segment(:'defaulter_seg_id'::uuid, current_date)
    where student_id = :'student_1_id'::uuid
  ),
  'Dynamic segment no longer includes transferred student'
);

-- But AC 4: Immutable audit snapshot STILL shows that student as targeted!
select ok(
  exists (
    select 1
    from public.message_audience_snapshot
    where campaign_id = :'campaign_audit_id'::uuid
      and student_id = :'student_1_id'::uuid
  ),
  'FR-M06 AC 4b: Audit snapshot permanently preserves transferred student as targeted at dispatch time'
);

select * from finish();
rollback;
