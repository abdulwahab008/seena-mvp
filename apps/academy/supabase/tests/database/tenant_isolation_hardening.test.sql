-- pgTAP tests for the tenant-isolation hardening pass: every function
-- fixed in 20260731040000_tenant_isolation_hardening.sql must reject a
-- cross-tenant reference with a NOT_FOUND-style error, never act on it.
--
-- One shared two-tenant setup: Tenant A owns every real resource under
-- test; Tenant B's owner is the attacker role attempting to reach across.
-- Owner is deliberately the attacking role throughout — it's the role
-- every "skip the narrower check" branch this audit found trusts most,
-- so it's the sharpest test of whether the tenant boundary actually holds.
begin;
select plan(19);

select public.provision_tenant('test-iso-a', 'Isolation Co A', 'owner-a@iso.test');
select id as tenant_a from public.tenant where slug = 'test-iso-a' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_a' \gset
select id as class1_a from public.class_level where tenant_id = :'tenant_a' and code = '1' \gset

select public.provision_tenant('test-iso-b', 'Isolation Co B', 'owner-b@iso.test');
select id as tenant_b from public.tenant where slug = 'test-iso-b' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset
select id as session_b from public.academic_session where tenant_id = :'tenant_b' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_a', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);

-- ── Tenant A's real resources ────────────────────────────────────────

select public.create_section(:'campus_a'::uuid, :'session_a'::uuid, :'class1_a'::uuid, 'A', 10) as section_a \gset
select public.create_subject('MATH-ISO', 'Mathematics', 'ریاضی') as subject_a \gset
select public.create_student(:'campus_a'::uuid, 'Iso Student A', '2015-01-01'::date, 'male') as student_a \gset
select public.create_staff(:'campus_a'::uuid, 'Iso Staff A', 'female', p_cnic => '4210112340091') as staff_a \gset

select public.create_enquiry(
  p_campus_id => :'campus_a', p_session_id => :'session_a', p_child_name => 'Offer Extend Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_a', p_parent_name => 'Parent A1',
  p_phone => '03001110001', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry_a1 \gset
select public.fn_submit_application(:'enquiry_a1'::uuid) as app_a1 \gset
select public.fn_issue_offer(:'app_a1'::uuid, 5000) as offer_a1 \gset

select public.create_enquiry(
  p_campus_id => :'campus_a', p_session_id => :'session_a', p_child_name => 'Offer Respond Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_a', p_parent_name => 'Parent A2',
  p_phone => '03001110002', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry_a2 \gset
select public.fn_submit_application(:'enquiry_a2'::uuid) as app_a2 \gset
select public.fn_issue_offer(:'app_a2'::uuid, 5000) as offer_a2 \gset

select public.create_enquiry(
  p_campus_id => :'campus_a', p_session_id => :'session_a', p_child_name => 'Offer Reinstate Child',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_a', p_parent_name => 'Parent A3',
  p_phone => '03001110003', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry_a3 \gset
select public.fn_submit_application(:'enquiry_a3'::uuid) as app_a3 \gset
select public.fn_issue_offer(:'app_a3'::uuid, 5000) as offer_a3 \gset
reset role;
update public.admission_offer set status = 'lapsed' where id = :'offer_a3';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_a', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);

select public.create_leave_type('CASUAL-ISO', 'Casual Leave', 10) as leave_type_a \gset
select public.fn_grant_leave_balance(:'staff_a'::uuid, :'leave_type_a'::uuid, 10);
select public.apply_for_leave(:'staff_a'::uuid, :'leave_type_a'::uuid, '2026-09-01'::date, '2026-09-01'::date, true) as leave_app_a \gset

-- ── Switch to Tenant B's owner: every call below reaches for Tenant A's
--    real ids and must be rejected, never act on them ──────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_b', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_b'))::text,
  true
);

select throws_ok(
  format('select public.fn_submit_application(%L)', :'enquiry_a1'),
  'ENQUIRY_NOT_FOUND',
  'fn_submit_application rejects another tenant''s enquiry_id'
);
select throws_ok(
  format('select public.fn_issue_offer(%L, 5000)', :'app_a1'),
  'APPLICATION_NOT_FOUND',
  'fn_issue_offer rejects another tenant''s application_id'
);
select throws_ok(
  format($$ select public.fn_extend_offer(%L, now() + interval '10 days', 'test') $$, :'offer_a1'),
  'OFFER_NOT_EXTENDABLE',
  'fn_extend_offer rejects another tenant''s offer_id'
);
select throws_ok(
  format($$ select public.fn_respond_to_offer(%L, 'accepted') $$, :'offer_a2'),
  'OFFER_NOT_FOUND',
  'fn_respond_to_offer rejects another tenant''s offer_id'
);
select throws_ok(
  format('select public.fn_reinstate_offer(%L)', :'offer_a3'),
  'OFFER_NOT_LAPSED',
  'fn_reinstate_offer rejects another tenant''s offer_id'
);

select throws_ok(
  format(
    $$ select public.create_enquiry(
         p_campus_id => %L, p_session_id => %L, p_child_name => 'x', p_dob => '2020-01-01'::date,
         p_class_applied_id => %L, p_parent_name => 'x', p_phone => '03009999999', p_whatsapp_opt_in => false, p_source => 'walk_in'
       ) $$,
    :'campus_a', :'session_a', :'class1_a'
  ),
  'CAMPUS_NOT_FOUND',
  'create_enquiry rejects another tenant''s campus_id even for an owner'
);

select throws_ok(
  format('select public.assign_class_teacher(%L, %L, current_date)', :'section_a', gen_random_uuid()),
  'SECTION_NOT_FOUND',
  'assign_class_teacher rejects another tenant''s section_id'
);
select throws_ok(
  format('select public.assign_subject_teacher(%L, %L, %L, current_date)', :'section_a', :'subject_a', gen_random_uuid()),
  'SECTION_NOT_FOUND',
  'assign_subject_teacher rejects another tenant''s section_id'
);

select throws_ok(
  format('select public.enrol_student(%L, %L)', :'section_a', gen_random_uuid()),
  'SECTION_NOT_FOUND',
  'enrol_student rejects another tenant''s section_id'
);
select public.create_section(:'campus_b'::uuid, :'session_b'::uuid, (select id from public.class_level where tenant_id = :'tenant_b' and code = '1'), 'B', 10) as section_b \gset
select throws_ok(
  format('select public.enrol_student(%L, %L)', :'section_b', :'student_a'),
  'STUDENT_NOT_FOUND',
  'enrol_student rejects another tenant''s student_id even with a real section of its own'
);

select throws_ok(
  format(
    $$ select public.create_section(%L, %L, %L, 'X', 5) $$,
    :'campus_a', :'session_a', :'class1_a'
  ),
  'CAMPUS_NOT_FOUND',
  'create_section rejects another tenant''s campus_id even for an owner'
);

select throws_ok(
  format('select public.fn_resequence_roll_numbers(%L, %L)', :'section_a', :'session_a'),
  'SECTION_NOT_FOUND',
  'fn_resequence_roll_numbers rejects another tenant''s section_id'
);

select throws_ok(
  format('select public.fn_readmit_student(%L, %L)', :'student_a', gen_random_uuid()),
  'STUDENT_NOT_FOUND',
  'fn_readmit_student rejects another tenant''s student_id'
);
select throws_ok(
  format('select public.fn_set_transport_optin(%L, %L, true)', :'student_a', :'session_a'),
  'STUDENT_NOT_FOUND',
  'fn_set_transport_optin rejects another tenant''s student_id'
);

select throws_ok(
  format(
    'select public.upsert_class_subject(%L::uuid, %L::uuid, %L::uuid, %L::uuid, 5::smallint)',
    :'campus_a', :'session_a', :'class1_a', :'subject_a'
  ),
  'CAMPUS_NOT_FOUND',
  'upsert_class_subject rejects another tenant''s campus_id even for an owner'
);

select throws_ok(
  format($$ select public.create_staff(%L, 'x', 'male') $$, :'campus_a'),
  'CAMPUS_NOT_FOUND',
  'create_staff rejects another tenant''s campus_id'
);

select throws_ok(
  format($$ select public.fn_decide_leave_application(%L, 'approved') $$, :'leave_app_a'),
  'APPLICATION_NOT_PENDING',
  'fn_decide_leave_application rejects another tenant''s application_id'
);
select throws_ok(
  format($$ select public.advance_leave_approval(%L, 'approved') $$, :'leave_app_a'),
  'APPLICATION_NOT_PENDING',
  'advance_leave_approval rejects another tenant''s application_id'
);
select throws_ok(
  format('select public.apply_for_leave(%L, %L, current_date, current_date, true)', :'staff_a', gen_random_uuid()),
  'STAFF_NOT_FOUND',
  'apply_for_leave rejects another tenant''s staff_id even for an owner acting on behalf of staff'
);

select * from finish();
rollback;
