-- pgTAP tests for FR-T04: Dues clearance gate before TC release.
--
-- Tests:
-- 1. get_clearance_summary() aggregates unpaid fee challans for a student.
-- 2. issue_transfer_certificate() is blocked when unpaid dues exist and no override reason is provided.
-- 3. Short override reason (< 20 chars) is refused by trigger / gate.
-- 4. Valid override reason (>= 20 chars) permits issuance, records override audit fields.
-- 5. Full dues clearance permits issuance with dues_cleared = 'Yes'.

begin;
select plan(15);

select extract(year from current_date)::int as y0 \gset

-- 1. Setup tenant, campus, session, user
select public.provision_tenant('test-dues-gate', 'Dues Gate Academy', 'owner@duesgate.test');
select id as tenant_id from public.tenant where slug = 'test-dues-gate' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as admin_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_uid', 'admin@duesgate.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_uid', :'tenant_id', 'owner', 'Dues Gate Owner');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_uid'
  )::text,
  true
);

-- 2. Setup section & students
select public.create_section(
  :'campus_id'::uuid, :'session_id'::uuid, :'class_id'::uuid, 'A', 40
) as section_id \gset

select public.create_student(:'campus_id'::uuid, 'Zubair Khan', '2012-05-10'::date, 'male') as zubair_id \gset

select public.enrol_student(
  p_section_id := :'section_id',
  p_student_id := :'zubair_id'
) as enrol_zubair \gset

-- Setup second student with cleared dues
select public.create_student(:'campus_id'::uuid, 'Ayesha Bibi', '2013-08-15'::date, 'female') as ayesha_id \gset

select public.enrol_student(
  p_section_id := :'section_id',
  p_student_id := :'ayesha_id'
) as enrol_ayesha \gset

-- 3. Create TC template
select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'Transfer Certificate',
  '<p>{{student.name_en}}, GR {{student.gr_number}}, left on {{enrolment.left_on}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_id'::uuid
) as tpl_v1 \gset
select public.activate_certificate_template(:'tpl_v1'::uuid) as _a \gset

-- 4. Create an unpaid challan for Zubair
reset role;
insert into public.fee_challan (
  tenant_id, campus_id, enrolment_id, session_id,
  billing_period, challan_no, issue_date, due_date,
  gross_paisa, net_paisa, status
) values (
  :'tenant_id', :'campus_id', :'enrol_zubair', :'session_id',
  (current_date - 30)::date, 'CH-GATE-001', (current_date - 30)::date, (current_date - 15)::date,
  500000, 500000, 'unpaid'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_uid'
  )::text,
  true
);

-- Trigger should have populated student_id
select is(
  (select student_id from public.fee_challan where challan_no = 'CH-GATE-001'),
  :'zubair_id'::uuid,
  'trg_fee_challan_set_student_id automatically populated student_id from enrolment'
);

-- 5. Test get_clearance_summary
select is(
  (select count(*)::int from public.get_clearance_summary(:'zubair_id'::uuid)),
  1,
  'get_clearance_summary returns 1 unpaid item for Zubair'
);

select is(
  (select source from public.get_clearance_summary(:'zubair_id'::uuid) limit 1),
  'fee_challan',
  'Clearance source is fee_challan'
);

select is(
  (select amount from public.get_clearance_summary(:'zubair_id'::uuid) limit 1),
  5000.00::numeric,
  'Clearance amount matches net_paisa in PKR (5000.00)'
);

select cmp_ok(
  (select days_outstanding from public.get_clearance_summary(:'zubair_id'::uuid) limit 1),
  '>=',
  14,
  'days_outstanding reflects overdue days since due_date'
);

-- Ayesha has no unpaid dues
select is(
  (select count(*)::int from public.get_clearance_summary(:'ayesha_id'::uuid)),
  0,
  'get_clearance_summary returns 0 unpaid items for Ayesha'
);

-- 6. Test issue_transfer_certificate blocked on unpaid dues without override
select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, current_date) $$, :'enrol_zubair'),
  '55000',
  'UNPAID_DUES_OUTSTANDING',
  'issue_transfer_certificate refuses to issue TC when student has unpaid dues and no override'
);

-- 7. Test issue_transfer_certificate refused with short override (< 20 chars)
select throws_ok(
  format($$ select public.issue_transfer_certificate(%L, current_date, null, null, null, 'en', 'Too short reason') $$, :'enrol_zubair'),
  '55000',
  'UNPAID_DUES_OUTSTANDING',
  'issue_transfer_certificate refuses override reason shorter than 20 characters'
);

-- 8. Test issue_transfer_certificate succeeds with valid override (>= 20 chars)
select public.issue_transfer_certificate(
  :'enrol_zubair'::uuid,
  current_date,
  'Family moving to Karachi',
  'Good',
  null,
  'en',
  'Principal approved TC release with installment payment plan signed by guardian'
)::text as zubair_tc_json \gset

select ok(
  :'zubair_tc_json' is not null,
  'issue_transfer_certificate succeeds with valid override reason'
);

-- Verify certificate_issue record contains override details
select is(
  (select override_reason from public.certificate_issue where enrolment_id = :'enrol_zubair'::uuid),
  'Principal approved TC release with installment payment plan signed by guardian',
  'certificate_issue records the override_reason'
);

select is(
  (select override_by from public.certificate_issue where enrolment_id = :'enrol_zubair'::uuid),
  :'admin_uid'::uuid,
  'certificate_issue records the override_by user'
);

select is(
  (select payload_snapshot->'values'->>'transfer.dues_cleared' from public.certificate_issue where enrolment_id = :'enrol_zubair'::uuid),
  'Overridden',
  'payload_snapshot marks transfer.dues_cleared as Overridden'
);

-- 9. Test Ayesha (no dues) succeeds without any override
select public.issue_transfer_certificate(
  :'enrol_ayesha'::uuid,
  current_date,
  'Graduation',
  'Excellent'
)::text as ayesha_tc_json \gset

select ok(
  :'ayesha_tc_json' is not null,
  'issue_transfer_certificate succeeds for student with no dues'
);

select is(
  (select payload_snapshot->'values'->>'transfer.dues_cleared' from public.certificate_issue where enrolment_id = :'enrol_ayesha'::uuid),
  'Yes',
  'payload_snapshot marks transfer.dues_cleared as Yes when no dues were outstanding'
);

select is(
  (select override_reason from public.certificate_issue where enrolment_id = :'enrol_ayesha'::uuid),
  null,
  'certificate_issue has null override_reason for student without dues'
);

select finish();
rollback;
