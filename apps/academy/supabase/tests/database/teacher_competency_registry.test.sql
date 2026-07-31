-- pgTAP tests for FR-E07: teacher subject competency registry.
begin;
select plan(22);

select public.provision_tenant('test-competency-co', 'Competency Co', 'owner@competencyco.test');
select id as tenant_id from public.tenant where slug = 'test-competency-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class12_id from public.class_level where tenant_id = :'tenant_id' and code = '12' \gset
select ordinal as class6_ordinal from public.class_level where id = :'class6_id' \gset
select ordinal as class9_ordinal from public.class_level where id = :'class9_id' \gset
select ordinal as class12_ordinal from public.class_level where id = :'class12_id' \gset

select public.provision_tenant('test-competency-other-co', 'Competency Other Co', 'owner@competencyotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-competency-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_class6_id from public.class_level where tenant_id = :'other_tenant_id' and code = '6' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 40) as section6_id \gset

select public.create_staff(:'campus_id'::uuid, 'Bilal', 'male', p_cnic => '42101-1234567-1') as bilal_id \gset
select public.create_staff(:'campus_id'::uuid, 'Ayesha', 'female', p_cnic => '42101-1234567-2') as ayesha_id \gset
select public.create_staff(:'campus_id'::uuid, 'Carla', 'female', p_cnic => '42101-1234567-3') as carla_id \gset
select public.create_staff(:'campus_id'::uuid, 'Danish', 'male', p_cnic => '42101-1234567-4') as danish_id \gset

select gen_random_uuid() as carla_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'carla_user_id', 'carla@competencyco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'carla_user_id', :'tenant_id', 'class_teacher', 'Carla');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.link_staff_user_account(:'carla_id'::uuid, :'carla_user_id'::uuid);

-- ── AC1: an out-of-range candidate is returned, ranked below an
--    exact-match candidate, and flagged — never hidden ────────────────

select public.declare_competency(:'bilal_id'::uuid, :'chem_id'::uuid, :'class6_ordinal'::smallint, :'class6_ordinal'::smallint);
select public.declare_competency(:'ayesha_id'::uuid, :'chem_id'::uuid, :'class9_ordinal'::smallint, :'class12_ordinal'::smallint);

select staff_id as top_staff_id from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class6_id'::uuid) limit 1 \gset
select is(
  :'top_staff_id'::uuid, :'bilal_id'::uuid,
  'AC: for class 6, the exact-match candidate (Bilal) ranks first'
);
select out_of_range as ayesha_flag from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class6_id'::uuid) where staff_id = :'ayesha_id'::uuid \gset
select is(
  :'ayesha_flag'::boolean, true,
  'AC: Ayesha (competent for 9-12, not 6) is still returned for class 6, flagged out_of_range rather than hidden'
);

select throws_ok(
  format('select public.declare_competency(%L, %L, 10::smallint, 5::smallint)', :'bilal_id', :'chem_id'),
  'INVALID_ORDINAL_RANGE',
  'a min ordinal greater than the max is rejected'
);

-- ── AC2: allocating a teacher with no competency row auto-creates one,
--    source=INFERRED, and warns the caller ─────────────────────────────

select public.assign_subject_teacher(:'section6_id'::uuid, :'chem_id'::uuid, :'carla_user_id'::uuid, '2026-08-01'::date) as carla_alloc \gset
select is(
  (:'carla_alloc'::jsonb ->> 'warning'),
  'NO_COMPETENCY_ON_RECORD',
  'AC: allocating a teacher with zero competency rows returns the NO_COMPETENCY_ON_RECORD warning, and the allocation still saves'
);
select is(
  (select source from public.teacher_subject_competency where staff_id = :'carla_id'::uuid and subject_id = :'chem_id'::uuid),
  'INFERRED'::public.competency_source_enum,
  'AC: a competency row is auto-created for Carla with source=INFERRED'
);
select is(
  (select min_class_ordinal from public.teacher_subject_competency where staff_id = :'carla_id'::uuid and subject_id = :'chem_id'::uuid),
  :'class6_ordinal'::smallint,
  'the inferred row is scoped to the class actually taught (class 6), not a guessed wider range'
);

-- A second allocation for a teacher who ALREADY has a competency row on
-- record carries no warning.
select gen_random_uuid() as bilal_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bilal_user_id', 'bilal@competencyco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bilal_user_id', :'tenant_id', 'class_teacher', 'Bilal');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.link_staff_user_account(:'bilal_id'::uuid, :'bilal_user_id'::uuid);
select public.assign_subject_teacher(:'section6_id'::uuid, :'chem_id'::uuid, :'bilal_user_id'::uuid, '2026-08-01'::date, 'assistant') as bilal_alloc \gset
select is(
  (:'bilal_alloc'::jsonb ->> 'warning'),
  null,
  'a teacher who already has a competency row on record carries no warning'
);

-- ── AC3: HR verifies a competency against a document; Verified outranks
--    Declared/Inferred in every suggestion list ────────────────────────

select public.verify_competency(:'bilal_id'::uuid, :'chem_id'::uuid, 'staff-documents/bilal-chem-degree.pdf') as verify_result \gset
select is(
  (select source from public.teacher_subject_competency where id = :'verify_result'::uuid),
  'VERIFIED'::public.competency_source_enum,
  'AC: verify_competency marks the row Verified'
);
select is(
  (select document_path from public.teacher_subject_competency where id = :'verify_result'::uuid),
  'staff-documents/bilal-chem-degree.pdf',
  'the verification document path is stored'
);
select ok(
  (select verified_at from public.teacher_subject_competency where id = :'verify_result'::uuid) is not null,
  'AC: verified_at is stamped'
);

select throws_ok(
  format('select public.verify_competency(%L, %L)', :'danish_id', :'chem_id'),
  'COMPETENCY_NOT_FOUND',
  'verifying a staff+subject pair with no existing row at all is refused'
);

-- Re-declaring an already-Verified row widens the range without
-- downgrading its source.
select public.declare_competency(:'bilal_id'::uuid, :'chem_id'::uuid, :'class6_ordinal'::smallint, :'class9_ordinal'::smallint);
select is(
  (select source from public.teacher_subject_competency where staff_id = :'bilal_id'::uuid and subject_id = :'chem_id'::uuid),
  'VERIFIED'::public.competency_source_enum,
  'AC: re-declaring an already-Verified row keeps it Verified — only the ordinal range moves'
);

select public.declare_competency(:'danish_id'::uuid, :'chem_id'::uuid, :'class6_ordinal'::smallint, :'class6_ordinal'::smallint);
select staff_id as top_after_verify from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class6_id'::uuid) limit 1 \gset
select is(
  :'top_after_verify'::uuid, :'bilal_id'::uuid,
  'AC: between two exact-match candidates, the Verified one (Bilal) ranks above the merely-Declared one (Danish)'
);

-- ── AC4: a deactivated staff member's rows are retained but excluded
--    from suggestions dated after the deactivation ─────────────────────

reset role;
update public.staff set employment_status = 'exited' where id = :'ayesha_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select ok(
  (select employment_status_changed_at from public.staff where id = :'ayesha_id'::uuid) is not null,
  'deactivating a staff member stamps employment_status_changed_at'
);
select is(
  (select count(*)::int from public.teacher_subject_competency where staff_id = :'ayesha_id'::uuid),
  1,
  'AC: the competency row is retained after deactivation, not deleted'
);
select is(
  (select count(*)::int from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class9_id'::uuid, (current_date + 1)) where staff_id = :'ayesha_id'::uuid),
  0,
  'AC: a suggestion dated after the deactivation excludes her'
);
select is(
  (select count(*)::int from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class9_id'::uuid, (current_date - 1)) where staff_id = :'ayesha_id'::uuid),
  1,
  'a suggestion dated before the deactivation still includes her'
);

-- A staff row exited with no recorded change date is conservatively
-- excluded from every suggestion, regardless of date. trg_staff_status_
-- changed_at only fires on UPDATE, so an INSERT that starts the row
-- already 'exited' (a data-migration/legacy-seed scenario, e.g. from
-- before this trigger existed) leaves employment_status_changed_at null —
-- exactly the case this branch has to defend against.
reset role;
insert into public.staff (tenant_id, campus_id, employee_code, id_document_type, cnic, gender, full_name, employment_status)
values (:'tenant_id', :'campus_id', 'EMP-GONE-1', 'cnic', '42101-1234567-5', 'male', 'Long Gone', 'exited')
returning id as gone_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.declare_competency(:'gone_id'::uuid, :'chem_id'::uuid, :'class9_ordinal'::smallint, :'class9_ordinal'::smallint);
select is(
  (select count(*)::int from public.suggest_substitute_teachers(:'chem_id'::uuid, :'class9_id'::uuid, (current_date - 1000)) where staff_id = :'gone_id'::uuid),
  0,
  'a staff member with no recorded status-change date is excluded even for a suggestion far in the past'
);

-- ── tenant isolation ──────────────────────────────────────────────────

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@competencyotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);
select public.create_staff(:'other_campus_id'::uuid, 'Other Tenant Staff', 'male', p_cnic => '42101-9999999-1') as other_staff_id \gset
select public.create_subject('MATH', 'Math', 'ریاضی') as other_subject_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.declare_competency(%L, %L, 1::smallint, 5::smallint)', :'other_staff_id', :'chem_id'),
  'STAFF_NOT_FOUND',
  'declare_competency refuses a foreign-tenant staff_id'
);
select throws_ok(
  format('select public.declare_competency(%L, %L, 1::smallint, 5::smallint)', :'bilal_id', :'other_subject_id'),
  'SUBJECT_NOT_FOUND',
  'declare_competency refuses a foreign-tenant subject_id'
);
select throws_ok(
  format('select public.suggest_substitute_teachers(%L, %L)', :'chem_id', :'other_class6_id'),
  'CLASS_LEVEL_NOT_FOUND',
  'suggest_substitute_teachers refuses a foreign-tenant class_level_id'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.teacher_subject_competency),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero competency rows via RLS despite several existing in the first tenant'
);

select * from finish();
rollback;
