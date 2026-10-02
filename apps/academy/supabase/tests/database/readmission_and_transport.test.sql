-- pgTAP tests for FR-C13 (readmission under the original GR number) and
-- FR-C07 (transport opt-in).
begin;
select plan(10);

select public.provision_tenant('test-readmit-co', 'Readmit Co', 'owner@readmitco.test');
select id as tenant_id from public.tenant where slug = 'test-readmit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class8_id from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class8_id', p_name => 'A', p_capacity => 40) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Ahmed Struck Off', '2013-01-01'::date, 'male', p_b_form_no => '3520212349999') as student_id \gset
select public.fn_change_student_status(:'student_id'::uuid, 'struck_off', 'disciplinary');

-- ── C13: duplicate probe finds the struck-off record ──────────────────

select is(
  (select gr_number from public.fn_find_readmission_candidates(p_b_form_no => '3520212349999')),
  (select gr_number from public.student where id = :'student_id'),
  'searching by B-Form surfaces the struck-off record with its original GR number before a duplicate could be saved'
);
select is(
  (select count(*)::int from public.fn_find_readmission_candidates(p_name_en => 'Ahmed Struck Off', p_dob => '2013-01-01'::date)),
  1,
  'name + DOB also finds the record for guardians who never had the B-Form on hand'
);

-- ── C13: readmission reuses the same student row and GR number ────────

select public.fn_readmit_student(:'student_id'::uuid, :'section_id'::uuid) as readmit_enrolment_id \gset
select is(
  (select status from public.student where id = :'student_id'),
  'active'::public.student_status,
  'readmission reactivates the same student row'
);
select is(
  (select count(*)::int from public.student where gr_number = (select gr_number from public.student where id = :'student_id')),
  1,
  'exactly one student row holds this GR number — readmission never mints a second one'
);
select is(
  (select section_id from public.enrolment where id = :'readmit_enrolment_id'),
  :'section_id',
  'a fresh enrolment row is created in the new class/section'
);

-- ── C13: no_readmission_flag blocks a Principal, only Owner can override ─

select public.create_student(:'campus_id'::uuid, 'Bilal Flagged', '2013-01-01'::date, 'male') as flagged_student_id \gset
select public.fn_change_student_status(:'flagged_student_id'::uuid, 'struck_off', 'disciplinary');
reset role;
update public.student set no_readmission_flag = true where id = :'flagged_student_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_readmit_student(%L, %L)', :'flagged_student_id', :'section_id'),
  'READMISSION_BLOCKED',
  'a Principal cannot readmit a no_readmission-flagged student at all'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_readmit_student(%L, %L)', :'flagged_student_id', :'section_id'),
  'OVERRIDE_REASON_REQUIRED',
  'an Owner can override, but only with a recorded reason'
);
select lives_ok(
  format('select public.fn_readmit_student(%L, %L, %L)', :'flagged_student_id', :'section_id', 'Family circumstances resolved, board approved'),
  'an Owner override with a reason succeeds'
);

-- ── C07: transport opt-in, unrouted list, month-boundary billing ──────

select public.create_student(:'campus_id'::uuid, 'Sana Commuter', '2014-01-01'::date, 'female') as commuter_id \gset
select public.fn_set_transport_optin(:'commuter_id'::uuid, :'session_id'::uuid, true, 'both', 'Gulberg');
select is(
  (select count(*)::int from public.v_unrouted_transport where student_id = :'commuter_id'),
  1,
  'an opted-in student with no route bound appears in the unrouted list'
);

reset role;
update public.student_transport set from_date = '2026-03-01'::date where student_id = :'commuter_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.fn_set_transport_optin(:'commuter_id'::uuid, :'session_id'::uuid, false);
select is(
  (select to_date from public.student_transport where student_id = :'commuter_id' and opt_in = true),
  (date_trunc('month', current_date) + interval '1 month - 1 day')::date,
  'opting out is billed through the end of the current month, not retroactively'
);

select * from finish();
rollback;
