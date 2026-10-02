-- ==============================================================================
-- pgTAP Test: FR-N09 Student self-scoped portal
-- ==============================================================================
begin;

select plan(27);

-- ── 1. Schema & Table Tests ──────────────────────────────────────────────────
select has_table('public', 'student_portal_account', 'Table student_portal_account exists');
select has_column('public', 'student_portal_account', 'id', 'Column id exists');
select has_column('public', 'student_portal_account', 'tenant_id', 'Column tenant_id exists');
select has_column('public', 'student_portal_account', 'campus_id', 'Column campus_id exists');
select has_column('public', 'student_portal_account', 'student_id', 'Column student_id exists');
select has_column('public', 'student_portal_account', 'user_id', 'Column user_id exists');
select has_column('public', 'student_portal_account', 'status', 'Column status exists');
select has_column('public', 'student_portal_account', 'must_change_password', 'Column must_change_password exists');
select has_function('public', 'my_student_id', 'Function my_student_id exists');
select has_function('public', 'provision_student_accounts', 'Function provision_student_accounts exists');
select has_function('public', 'deprovision_on_tc', 'Function deprovision_on_tc exists');
select has_function('public', 'change_student_password', 'Function change_student_password exists');
select has_function('public', 'resolve_student_login', 'Function resolve_student_login exists');

-- ── 2. Seed Test Environment ─────────────────────────────────────────────────
do $$
declare
  v_tenant_id uuid := '88888888-8888-8888-8888-888888888888';
  v_campus_id uuid := '99999999-9999-9999-9999-999999999999';
  v_session_id uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_term_id uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  v_cl_5 uuid := '55555555-5555-5555-5555-555555555555';
  v_cl_6 uuid := '66666666-6666-6666-6666-666666666666';
  v_sec_5 uuid := '55555555-0000-0000-0000-000000000000';
  v_sec_6 uuid := '66666666-0000-0000-0000-000000000000';
  v_stu_5 uuid := '55555555-1111-1111-1111-111111111111';
  v_stu_6 uuid := '66666666-1111-1111-1111-111111111111';
  v_stu_other uuid := '66666666-2222-2222-2222-222222222222';
  v_enr_6 uuid := '66666666-3333-3333-3333-333333333333';
  v_enr_other uuid := '66666666-4444-4444-4444-444444444444';
  v_guardian_id uuid := '77777777-1111-1111-1111-111111111111';
  v_guardian_user uuid := '77777777-2222-2222-2222-222222222222';
  v_student_user uuid := '66666666-9999-9999-9999-999999999999';
  v_subject_id uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc';
  v_exam_subj_id uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd';
begin
  -- Authenticate as owner for seeding
  perform set_config('request.jwt.claims', jsonb_build_object(
    'tenant_id', v_tenant_id,
    'app_role', 'owner',
    'campus_ids', jsonb_build_array(v_campus_id)
  )::text, true);

  -- Tenant & Campus
  insert into public.tenant (id, name, slug)
  values (v_tenant_id, 'Student Portal Test Tenant', 'student-portal-tenant')
  on conflict (id) do nothing;

  insert into public.campus (id, tenant_id, name, code)
  values (v_campus_id, v_tenant_id, 'Student Portal Campus', 'SPC')
  on conflict (id) do nothing;

  insert into public.academic_session (id, tenant_id, name, starts_on, ends_on, is_current)
  values (v_session_id, v_tenant_id, '2026-2027', '2026-08-01', '2027-06-30', true)
  on conflict (id) do nothing;

  insert into public.exam_term (id, tenant_id, campus_id, session_id, code, name, sequence)
  values (v_term_id, v_tenant_id, v_campus_id, v_session_id, 'MID', 'Mid Term', 1)
  on conflict (id) do nothing;

  -- Campus Portal Policy: min class 6, show_rank false
  insert into public.campus_portal_policy (
    campus_id, tenant_id, min_class_for_student_login, show_rank
  ) values (
    v_campus_id, v_tenant_id, 6, false
  ) on conflict (campus_id) do update
  set min_class_for_student_login = 6, show_rank = false;

  -- Class Levels (Class 5 ordinal 6, Class 6 ordinal 7)
  insert into public.class_level (id, tenant_id, code, name_en, ordinal)
  values (v_cl_5, v_tenant_id, '5', 'Class 5', 6)
  on conflict (id) do nothing;

  insert into public.class_level (id, tenant_id, code, name_en, ordinal)
  values (v_cl_6, v_tenant_id, '6', 'Class 6', 7)
  on conflict (id) do nothing;

  -- Sections
  insert into public.class_section (id, tenant_id, campus_id, session_id, class_level_id, name, capacity)
  values (v_sec_5, v_tenant_id, v_campus_id, v_session_id, v_cl_5, '5-A', 30)
  on conflict (id) do nothing;

  insert into public.class_section (id, tenant_id, campus_id, session_id, class_level_id, name, capacity)
  values (v_sec_6, v_tenant_id, v_campus_id, v_session_id, v_cl_6, '6-A', 30)
  on conflict (id) do nothing;

  -- Students (one in Class 5, two in Class 6)
  insert into public.student (id, tenant_id, campus_id, gr_number, name_en, dob, gender, status)
  values (v_stu_5, v_tenant_id, v_campus_id, 'GR-000005', 'Student Five', '2016-01-01', 'male', 'active')
  on conflict (id) do nothing;

  insert into public.student (id, tenant_id, campus_id, gr_number, name_en, dob, gender, status)
  values (v_stu_6, v_tenant_id, v_campus_id, 'GR-000006', 'Student Six', '2015-01-01', 'female', 'active')
  on conflict (id) do nothing;

  insert into public.student (id, tenant_id, campus_id, gr_number, name_en, dob, gender, status)
  values (v_stu_other, v_tenant_id, v_campus_id, 'GR-000007', 'Peer Student', '2015-02-01', 'male', 'active')
  on conflict (id) do nothing;

  -- Enrolments
  insert into public.enrolment (id, tenant_id, campus_id, session_id, class_level_id, section_id, student_id, status)
  values (gen_random_uuid(), v_tenant_id, v_campus_id, v_session_id, v_cl_5, v_sec_5, v_stu_5, 'active')
  on conflict (student_id, session_id) do nothing;

  insert into public.enrolment (id, tenant_id, campus_id, session_id, class_level_id, section_id, student_id, status)
  values (v_enr_6, v_tenant_id, v_campus_id, v_session_id, v_cl_6, v_sec_6, v_stu_6, 'active')
  on conflict (student_id, session_id) do nothing;

  insert into public.enrolment (id, tenant_id, campus_id, session_id, class_level_id, section_id, student_id, status)
  values (v_enr_other, v_tenant_id, v_campus_id, v_session_id, v_cl_6, v_sec_6, v_stu_other, 'active')
  on conflict (student_id, session_id) do nothing;

  -- Guardian for Student Six
  insert into auth.users (id, instance_id, email, encrypted_password, aud, role)
  values (v_guardian_user, '00000000-0000-0000-0000-000000000000', 'parent-six@example.com', 'dummy', 'authenticated', 'authenticated')
  on conflict (id) do nothing;

  insert into public.guardian (id, tenant_id, name_en, auth_user_id, phone_e164)
  values (v_guardian_id, v_tenant_id, 'Father Six', v_guardian_user, '+923000000006')
  on conflict (id) do nothing;

  insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_academic, receives_billing)
  values (v_tenant_id, v_stu_6, v_guardian_id, 'father', true, true, true)
  on conflict (student_id, guardian_id) do nothing;

  -- Fee Challan for Student Six (AC 1 test)
  insert into public.fee_challan (
    id, tenant_id, campus_id, enrolment_id, session_id, student_id, challan_no,
    billing_period, due_date, gross_paisa, net_paisa, status
  ) values (
    gen_random_uuid(), v_tenant_id, v_campus_id, v_enr_6, v_session_id, v_stu_6, 'CH-006',
    '2026-08-01', '2026-08-15', 500000, 500000, 'unpaid'
  );

  -- Subject & Exam Subject
  insert into public.subject (id, tenant_id, code, name_en)
  values (v_subject_id, v_tenant_id, 'MATH', 'Mathematics')
  on conflict (id) do nothing;

  insert into public.class_subject (
    id, tenant_id, campus_id, session_id, class_level_id, subject_id, weekly_periods
  ) values (
    'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', v_tenant_id, v_campus_id, v_session_id, v_cl_6, v_subject_id, 5
  ) on conflict (id) do nothing;

  insert into public.exam_subject (id, tenant_id, campus_id, exam_term_id, class_subject_id)
  values (v_exam_subj_id, v_tenant_id, v_campus_id, v_term_id, 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')
  on conflict (id) do nothing;

  -- Subject Results for Student Six (92) and Peer (85)
  insert into public.subject_result (
    tenant_id, campus_id, exam_term_id, section_id, exam_subject_id, enrolment_id,
    subject_id, obtained, max_marks, is_pass
  ) values (
    v_tenant_id, v_campus_id, v_term_id, v_sec_6, v_exam_subj_id, v_enr_6,
    v_subject_id, 92, 100, true
  ), (
    v_tenant_id, v_campus_id, v_term_id, v_sec_6, v_exam_subj_id, v_enr_other,
    v_subject_id, 85, 100, true
  );

  -- Result Positions (Student Six rank 1, Peer rank 2)
  insert into public.result_position (
    tenant_id, campus_id, exam_term_id, class_level_id, section_id, enrolment_id,
    total_obtained, total_max, rank_in_section, rank_in_class, ranked_out_of,
    ranked_out_of_class, is_ranked, rank_policy
  ) values (
    v_tenant_id, v_campus_id, v_term_id, v_cl_6, v_sec_6, v_enr_6,
    92, 100, 1, 1, 2, 2, true, 'include_all'
  ), (
    v_tenant_id, v_campus_id, v_term_id, v_cl_6, v_sec_6, v_enr_other,
    85, 100, 2, 2, 2, 2, true, 'include_all'
  );
end;
$$;

-- ── 3. Test Provisioning with Minimum Class Rule ─────────────────────────────
select results_eq(
  $$
    select count(*)::int
    from public.provision_student_accounts('99999999-9999-9999-9999-999999999999');
  $$,
  $$ values (2) $$,
  'FR-N09 Provisioning: Exactly 2 students provisioned (Class 6 students), Class 5 student is skipped'
);

-- Verify Student Six has portal account with must_change_password = true
select is(
  (select must_change_password from public.student_portal_account where student_id = '66666666-1111-1111-1111-111111111111'),
  true,
  'FR-N09 AC 4: Student portal account created with must_change_password = true'
);

-- ── 4. AC 1: Dues and Fee Data are Completely Denied to Student ──────────────
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', (select user_id from public.student_portal_account where student_id = '66666666-1111-1111-1111-111111111111'),
  'app_role', 'student',
  'tenant_id', '88888888-8888-8888-8888-888888888888',
  'campus_ids', jsonb_build_array('99999999-9999-9999-9999-999999999999')
)::text, true);
set local role authenticated;

select is(
  (select count(*)::int from public.fee_challan where student_id = '66666666-1111-1111-1111-111111111111'),
  0,
  'FR-N09 AC 1: Student account cannot see fee_challan (0 rows, dues hidden)'
);

select is(
  (select count(*)::int from public.student_guardian),
  0,
  'FR-N09 AC 1: Student account is denied guardian contact details (0 rows)'
);

-- ── 5. AC 2: Results & Rank Exposure Gating ─────────────────────────────────
-- Student can see their own subject_result
select is(
  (select count(*)::int from public.subject_result where enrolment_id = '66666666-3333-3333-3333-333333333333'),
  1,
  'FR-N09 AC 2: Student can see their own subject marks'
);

-- Student CANNOT see peer student's marks
select is(
  (select count(*)::int from public.subject_result where enrolment_id = '66666666-4444-4444-4444-444444444444'),
  0,
  'FR-N09 AC 2: Student cannot see peer student marks'
);

-- With show_rank = false, student cannot read any result_position rows
select is(
  (select count(*)::int from public.result_position),
  0,
  'FR-N09 AC 2: When show_rank is disabled, student cannot see rank list or own rank'
);

-- Enable show_rank = true
reset role;
update public.campus_portal_policy
set show_rank = true
where campus_id = '99999999-9999-9999-9999-999999999999';

select set_config('request.jwt.claims', jsonb_build_object(
  'sub', (select user_id from public.student_portal_account where student_id = '66666666-1111-1111-1111-111111111111'),
  'app_role', 'student',
  'tenant_id', '88888888-8888-8888-8888-888888888888',
  'campus_ids', jsonb_build_array('99999999-9999-9999-9999-999999999999')
)::text, true);
set local role authenticated;

-- Now student can see their OWN rank
select is(
  (select count(*)::int from public.result_position where enrolment_id = '66666666-3333-3333-3333-333333333333'),
  1,
  'FR-N09 AC 2: When show_rank is enabled, student can see their own rank'
);

-- But student STILL CANNOT see peer student's rank
select is(
  (select count(*)::int from public.result_position where enrolment_id = '66666666-4444-4444-4444-444444444444'),
  0,
  'FR-N09 AC 2: When show_rank is enabled, student still cannot see other students rank'
);

-- ── 6. AC 4: Password Change Flow ───────────────────────────────────────────
select is(
  public.change_student_password('BrandNewPassword123!'),
  true,
  'FR-N09 AC 4: change_student_password RPC succeeds'
);

select is(
  (select must_change_password from public.student_portal_account where student_id = '66666666-1111-1111-1111-111111111111'),
  false,
  'FR-N09 AC 4: must_change_password is now false after password change'
);

-- ── 7. AC 3: Deprovision on Transfer Certificate ─────────────────────────────
reset role;

-- Setup Certificate Template
insert into public.certificate_template (
  id, tenant_id, campus_id, certificate_type, language, version, title, body_html, merge_field_whitelist, page_size, status
) values (
  '89e4c74b-21f5-4884-9f51-459243e4d6ff',
  '88888888-8888-8888-8888-888888888888',
  '99999999-9999-9999-9999-999999999999',
  'transfer',
  'en',
  1,
  'Transfer Certificate',
  '<p>Transfer</p>',
  '[]'::jsonb,
  'A4',
  'draft'
) on conflict (id) do nothing;

-- Issue a Transfer Certificate for Student Six
insert into public.certificate_issue (
  tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
  serial_no, template_id, template_version, language, status, pdf_path, payload_snapshot
) values (
  '88888888-8888-8888-8888-888888888888',
  '99999999-9999-9999-9999-999999999999',
  '66666666-1111-1111-1111-111111111111',
  '66666666-3333-3333-3333-333333333333',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  'transfer',
  'TC-2026-0001',
  '89e4c74b-21f5-4884-9f51-459243e4d6ff',
  1,
  'en',
  'issued',
  'tc-2026-0001.pdf',
  '{"reason": "Relocation"}'::jsonb
);

-- Run nightly deprovision job
select is(
  public.deprovision_on_tc(),
  1,
  'FR-N09 AC 3: deprovision_on_tc disables 1 student account on Transfer Certificate issuance'
);

select is(
  (select status from public.student_portal_account where student_id = '66666666-1111-1111-1111-111111111111'),
  'disabled',
  'FR-N09 AC 3: Student portal account status is set to disabled'
);

-- Verify Guardian retains archived read access
select set_config('request.jwt.claims', jsonb_build_object(
  'sub', '77777777-2222-2222-2222-222222222222',
  'app_role', 'parent',
  'tenant_id', '88888888-8888-8888-8888-888888888888',
  'campus_ids', jsonb_build_array('99999999-9999-9999-9999-999999999999')
)::text, true);
set local role authenticated;

select is(
  (select count(*)::int from public.student where id = '66666666-1111-1111-1111-111111111111'),
  1,
  'FR-N09 AC 3: Guardian retains read access to student records after TC'
);

select finish();
rollback;
