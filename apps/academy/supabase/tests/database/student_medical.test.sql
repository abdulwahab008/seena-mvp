-- pgTAP tests for FR-C05: medical and disability data, restrictively.
begin;
select plan(8);

select public.provision_tenant('test-medical-co', 'Medical Co', 'owner@medicalco.test');
select id as tenant_id from public.tenant where slug = 'test-medical-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset

-- A class teacher, seeded directly (mirrors the FR-E08 test's pattern).
select gen_random_uuid() as teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_id', 'teacher@medicalco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 40) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Zara Allergic', '2014-01-01'::date, 'female') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid);

select public.fn_upsert_student_medical(
  :'student_id'::uuid, p_allergies => array['peanuts'], p_has_critical_allergy => true,
  p_emergency_contact_name => 'Mrs. Allergic', p_emergency_contact_phone => '03001234567'
);

-- ── direct table SELECT returns nothing, even to the owner ────────────

select is(
  (select count(*)::int from public.student_medical where student_id = :'student_id'),
  0,
  'a direct SELECT against student_medical returns zero rows even for the owner — there is no SELECT policy at all'
);

-- ── a subject teacher who does not teach the student is refused entirely ─

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_get_student_medical(%L)', :'student_id'),
  'FORBIDDEN',
  'a subject teacher with no relationship to this student cannot read the medical record at all'
);

-- ── the CURRENT class teacher (FR-E08) can read it ─────────────────────

-- Still owner here (from the throws_ok block above's role switch — no,
-- wait, that switched to subject_teacher; switch back to owner to make
-- this call), then hand the post to the teacher.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_id'::uuid, current_date);

-- Now act as the teacher: auth.uid() must resolve to teacher_id for the
-- "current class teacher" check inside fn_get_student_medical to match.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'teacher_id', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
-- One call, not two: each authorized call logs to phi_access_log, and the
-- later "exactly one read logged" check needs this to be the only read.
select (public.fn_get_student_medical(:'student_id'::uuid)).allergies[1] as first_allergy \gset
select is(:'first_allergy'::text, 'peanuts'::text, 'the section''s current class teacher reads the actual allergy detail');

-- ── every authorized read is logged ────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.phi_access_log where student_id = :'student_id' and accessed_by = :'teacher_id'),
  1,
  'the class teacher''s read was logged to phi_access_log'
);

-- ── the flags function exposes only the boolean, broadly ──────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select has_critical_allergy from public.fn_student_medical_flags() where student_id = :'student_id'),
  true,
  'any campus-scoped staff (even one FORBIDDEN from the full record) can see the critical-allergy flag'
);

-- ── write access is Principal/Owner/Nurse only ─────────────────────────

select throws_ok(
  format($$ select public.fn_upsert_student_medical(%L, p_allergies => array['dust']) $$, :'student_id'),
  'FORBIDDEN',
  'a subject teacher cannot write to the medical record'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'nurse', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format($$ select public.fn_upsert_student_medical(%L, p_allergies => array['peanuts', 'dust']) $$, :'student_id'),
  'a nurse can update the medical record'
);
reset role;
select is(
  (select array_length(allergies, 1) from public.student_medical where student_id = :'student_id'),
  2,
  'the update landed (verified as superuser, since even this check has no direct SELECT path)'
);

select * from finish();
rollback;
