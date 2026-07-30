-- pgTAP tests for FR-D01 (staff master profile) and FR-D09 (configurable
-- leave types).
begin;
select plan(12);

select public.provision_tenant('test-staff-hr-co', 'Staff HR Co', 'owner@staffhrco.test');
select id as tenant_id from public.tenant where slug = 'test-staff-hr-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select code as campus_code from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── D01: gapless, campus-prefixed employee codes ────────────────────

select public.create_staff(:'campus_id'::uuid, 'Fatima Bibi', 'female', p_cnic => '4210112340001') as fatima_id \gset
select is(
  (select employee_code from public.staff where id = :'fatima_id'),
  'SA-' || :'campus_code' || '-0001',
  'the first staff member at this campus gets employee code SA-<campus>-0001'
);

select public.create_staff(:'campus_id'::uuid, 'Usman Ali', 'male', p_cnic => '4210112340002') as usman_id \gset
select is(
  (select employee_code from public.staff where id = :'usman_id'),
  'SA-' || :'campus_code' || '-0002',
  'the second staff member gets the next gapless code, -0002'
);

-- ── D01: passport path leaves CNIC null ────────────────────────────

select public.create_staff(:'campus_id'::uuid, 'John Foreign Teacher', 'male', p_id_document_type => 'passport', p_passport_no => 'AB1234567') as foreign_id \gset
select is(
  (select cnic from public.staff where id = :'foreign_id'),
  null,
  'a passport-documented staff member has no CNIC recorded'
);

-- ── D01: CNIC uniqueness is tenant-scoped and partial on active ──────

select throws_ok(
  format($$ select public.create_staff(%L, 'Fatima Duplicate', 'female', p_cnic => '4210112340001') $$, :'campus_id'),
  'CNIC_CONFLICT',
  'a second active staff member with the same CNIC is rejected'
);

reset role;
update public.staff set employment_status = 'exited' where id = :'fatima_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format($$ select public.create_staff(%L, 'Fatima Rehire', 'female', p_cnic => '4210112340001') $$, :'campus_id'),
  'once the original holder has exited, the same CNIC is free again — the uniqueness index is partial on active'
);

-- ── D01: multi-campus attachment ────────────────────────────────────

select public.create_campus(p_code => 'KHI2', p_name => 'Karachi Campus 2') as campus2_id \gset
select public.attach_staff_campus(:'usman_id'::uuid, :'campus2_id'::uuid);
select is(
  (select count(*)::int from public.staff_campus where staff_id = :'usman_id'),
  2,
  'Usman is now attached to two campuses (his primary plus the new one)'
);

-- ── D09: leave types, versioned by effective_from ──────────────────

select public.create_leave_type(
  'MATERNITY', 'Maternity Leave', 90, p_eligible_genders => array['female']
) as maternity_id \gset
select public.create_leave_type('SICK', 'Sick Leave', 15, p_doc_required_after_days => 3::smallint) as sick_id \gset

select is(
  (select bool_or(code = 'MATERNITY') from public.eligible_leave_types(:'usman_id'::uuid)),
  false,
  'Maternity leave is not in the eligible list for a male staff member'
);
select is(
  (select bool_or(code = 'MATERNITY') from public.eligible_leave_types(:'fatima_id'::uuid)),
  true,
  'Maternity leave IS eligible for a female staff member'
);
select is(
  (select doc_required_after_days from public.leave_type where id = :'sick_id'),
  3::smallint,
  'the document-required-after-N-days threshold is stored on the leave type'
);

-- Entitlement change: a new versioned row, old one untouched.
select public.create_leave_type('SICK', 'Sick Leave', 12, p_effective_from => (current_date + 30)) as sick_v2_id \gset
select is(
  (select entitlement_days from public.leave_type where id = :'sick_id'),
  15.00,
  'the original 15-day Sick Leave row is unchanged — a new version was inserted, not an update'
);
select is(
  (select count(*)::int from public.leave_type where tenant_id = :'tenant_id' and code = 'SICK'),
  2,
  'two versions of Sick Leave now exist: the current one and the future 12-day one'
);

-- ── role gate ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.create_staff(%L, 'Unauthorized Hire', 'male', p_cnic => '4210112349999') $$, :'campus_id'),
  'FORBIDDEN',
  'a subject teacher cannot create a staff record'
);

select * from finish();
rollback;
