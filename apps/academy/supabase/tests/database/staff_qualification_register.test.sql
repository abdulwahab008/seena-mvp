-- pgTAP tests for FR-D02 (staff qualification and certification register).
begin;
select plan(17);

select public.provision_tenant('test-qual-co', 'Qualification Co', 'owner@qualco.test');
select id as tenant_id from public.tenant where slug = 'test-qual-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as hr_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'hr_user_id', 'hr@qualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'hr_user_id', :'tenant_id', 'hr_manager', 'HR Manager');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@qualco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Chemistry Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'chem_id'::uuid, 5::smallint);

-- ── AC1: two qualification rows, highest_level resolves correctly ──────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select public.add_staff_qualification(:'teacher_user_id'::uuid, 'master'::public.qualification_level, 'Chemistry', 'University of the Punjab', 2014::smallint) as msc_id \gset
select public.add_staff_qualification(:'teacher_user_id'::uuid, 'bachelor'::public.qualification_level, 'Education', 'Allama Iqbal Open University', 2016::smallint) as bed_id \gset
select is(
  (select count(*)::int from public.staff_qualification where staff_id = :'teacher_user_id'::uuid),
  2,
  'AC1: both qualification rows are listed'
);
select is(
  (public.staff_highest_qualification(:'teacher_user_id'::uuid))::text,
  'master',
  'AC1: highest_level resolves to master (MSc over BEd)'
);

-- ── a teacher cannot record a qualification on someone else''s behalf ──

select throws_ok(
  format(
    $$ select public.add_staff_qualification(%L, 'master'::public.qualification_level, 'Physics', 'Some University', 2015::smallint) $$,
    :'hr_user_id'
  ),
  'FORBIDDEN',
  'a plain teacher cannot add a qualification for another staff member'
);

-- ── AC2: a teacher can never verify their own qualification ────────────

select throws_ok(
  format($$ select public.verify_staff_qualification(%L, 'verified'::public.qualification_verification_status) $$, :'msc_id'),
  'FORBIDDEN',
  'AC2: a Teacher attempting to verify their own qualification is rejected (role gate)'
);
select is(
  (select verification_status from public.staff_qualification where id = :'msc_id'::uuid)::text,
  'pending',
  'AC2: the value is unchanged after the rejected attempt'
);

-- HR verifying their OWN qualification is also rejected — self-
-- verification is blocked regardless of which role holds it.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'hr_user_id')::text,
  true
);
select public.add_staff_qualification(:'hr_user_id'::uuid, 'bachelor'::public.qualification_level, 'Human Resources', 'LUMS', 2018::smallint) as hr_own_id \gset
select throws_ok(
  format($$ select public.verify_staff_qualification(%L, 'verified'::public.qualification_verification_status) $$, :'hr_own_id'),
  'FORBIDDEN',
  'AC2 (defense in depth): an HR Manager cannot verify their own qualification either'
);

-- ── HR verifies the teacher''s MSc — a real, cross-staff verification ──

select public.verify_staff_qualification(:'msc_id'::uuid, 'verified'::public.qualification_verification_status);
select is(
  (select verification_status from public.staff_qualification where id = :'msc_id'::uuid)::text,
  'verified',
  'HR verifying another staff member''s qualification succeeds'
);

-- ── AC3: deleting the linked document reverts verification to pending,
--    and the change lands in audit_log ─────────────────────────────────

select public.add_staff_document(:'teacher_user_id'::uuid, 'MSc Chemistry degree scan') as doc_id \gset

-- staff_qualification has no UPDATE policy at all (function-gated writes
-- only) — linking the document directly is test setup, not an AC, so it
-- runs as superuser rather than inventing a one-off RPC just for this.
reset role;
update public.staff_qualification set document_id = :'doc_id'::uuid where id = :'msc_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'hr_user_id')::text,
  true
);

-- audit_log's own read policy only admits owner/principal/super_admin —
-- not hr_manager — so both counts are read as superuser, bypassing RLS
-- entirely (the point being tested is that the row exists at all).
reset role;
select count(*)::int as audit_count_before from public.audit_log where table_name = 'staff_qualification' and row_id = :'msc_id'::uuid and action = 'update' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'hr_user_id')::text,
  true
);

select public.delete_staff_document(:'doc_id'::uuid);
select is(
  (select verification_status from public.staff_qualification where id = :'msc_id'::uuid)::text,
  'pending',
  'AC3: deleting the linked document reverts verification to pending'
);
select ok(
  (select verified_by from public.staff_qualification where id = :'msc_id'::uuid) is null,
  'AC3: verified_by is cleared on revert'
);
reset role;
select ok(
  (select count(*)::int from public.audit_log where table_name = 'staff_qualification' and row_id = :'msc_id'::uuid and action = 'update') > :'audit_count_before',
  'AC3: the revert is written to audit_log'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'hr_user_id')::text,
  true
);

-- ── AC4: assigning a teacher with zero verified qualifications carries
--    a non-blocking warning; the assignment still saves ───────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.assign_subject_teacher(:'section_id'::uuid, :'chem_id'::uuid, :'teacher_user_id'::uuid, '2026-08-01'::date) as alloc1 \gset
select is(
  (:'alloc1'::jsonb ->> 'qualification_warning'),
  'QUALIFICATION_UNVERIFIED',
  'AC4: assigning a teacher with zero VERIFIED qualifications (the MSc reverted to pending above) carries the warning'
);
select ok(
  (:'alloc1'::jsonb ->> 'id') is not null,
  'AC4: the assignment itself still saved despite the warning'
);

-- Once the teacher actually has a verified qualification, a fresh
-- assignment carries no warning.
select public.verify_staff_qualification(:'msc_id'::uuid, 'verified'::public.qualification_verification_status);
select public.create_subject('PHY', 'Physics', 'فزکس') as phy_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy_id'::uuid, 5::smallint);
select public.assign_subject_teacher(:'section_id'::uuid, :'phy_id'::uuid, :'teacher_user_id'::uuid, '2026-08-01'::date) as alloc2 \gset
select ok(
  (:'alloc2'::jsonb ->> 'qualification_warning') is null,
  'AC4: a teacher with at least one verified qualification carries no warning on a fresh assignment'
);

-- ── a plain subject teacher cannot verify or manage documents ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.verify_staff_qualification(%L, 'verified'::public.qualification_verification_status) $$, :'bed_id'),
  'FORBIDDEN',
  'a subject teacher cannot verify any qualification'
);
select throws_ok(
  format($$ select public.add_staff_document(%L, 'Some doc') $$, :'hr_user_id'),
  'FORBIDDEN',
  'a subject teacher cannot add a staff document for another staff member'
);

-- ── tenant isolation ────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
reset role;
select public.provision_tenant('test-qual-other-co', 'Qualification Other Co', 'owner@qualotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-qual-other-co' \gset
select gen_random_uuid() as other_owner_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_owner_id', 'owner2@qualotherco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_owner_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_owner_id')::text,
  true
);
select is(
  (select count(*)::int from public.staff_qualification),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero qualification rows via RLS'
);
select is(
  (public.staff_highest_qualification(:'teacher_user_id'::uuid)) is null,
  true,
  'AC/defense-in-depth: staff_highest_qualification resolves nothing for a staff member outside the caller''s own tenant'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select * from finish();
rollback;
