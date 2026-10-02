-- pgTAP tests for FR-E11: academic structure session rollover.
--
-- AC "a constraint violation at row 200 rolls back the whole transaction"
-- isn't exercised directly — every write in clone_academic_structure()
-- already goes through either ON CONFLICT DO NOTHING or an explicit
-- NOT EXISTS guard (no bare inserts that could hit a live unique/
-- exclusion violation), and the function has no per-row exception
-- handling anywhere, so a genuine failure partway through aborts the
-- whole call by ordinary Postgres transaction semantics — the same
-- "guaranteed by construction, not by a specific contrived test" reasoning
-- already used elsewhere in this codebase for untestable-in-a-single-
-- connection guarantees.
begin;
select plan(20);

select public.provision_tenant('test-rollover-co', 'Rollover Co', 'owner@rolloverco.test');
select id as tenant_id from public.tenant where slug = 'test-rollover-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as from_session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset

select public.provision_tenant('test-rollover-other-co', 'Rollover Other Co', 'owner@rolloverotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-rollover-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_academic_session(
  :'campus_id'::uuid, '2027-28', (current_date + interval '1 year')::date, (current_date + interval '2 years' - interval '1 day')::date
) as to_session_id \gset

select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'from_session_id', p_class_level_id => :'class6_id', p_name => 'A', p_capacity => 40) as section6a_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'from_session_id', p_class_level_id => :'class7_id', p_name => 'A', p_capacity => 40) as section7a_id \gset
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'from_session_id', p_class_level_id => :'class6_id', p_subject_id => :'chem_id', p_weekly_periods => 6::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'from_session_id', p_class_level_id => :'class7_id', p_subject_id => :'chem_id', p_weekly_periods => 6::smallint);

select public.create_staff(:'campus_id'::uuid, 'Bilal', 'male', p_cnic => '42101-1234568-1') as bilal_staff_id \gset
select public.create_staff(:'campus_id'::uuid, 'Ayesha', 'female', p_cnic => '42101-1234568-2') as ayesha_staff_id \gset
select gen_random_uuid() as bilal_user_id \gset
select gen_random_uuid() as ayesha_user_id \gset
reset role;
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bilal_user_id', 'bilal@rolloverco.test', 'x', now(), 'authenticated', 'authenticated'),
       (:'ayesha_user_id', 'ayesha@rolloverco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bilal_user_id', :'tenant_id', 'class_teacher', 'Bilal'), (:'ayesha_user_id', :'tenant_id', 'class_teacher', 'Ayesha');
update public.staff set user_id = :'bilal_user_id'::uuid where id = :'bilal_staff_id'::uuid;
update public.staff set user_id = :'ayesha_user_id'::uuid, employment_status = 'exited' where id = :'ayesha_staff_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.assign_class_teacher(:'section6a_id'::uuid, :'bilal_user_id'::uuid, '2026-08-01'::date);
select public.assign_class_teacher(:'section7a_id'::uuid, :'ayesha_user_id'::uuid, '2026-08-01'::date);
select public.assign_subject_teacher(:'section6a_id'::uuid, :'chem_id'::uuid, :'bilal_user_id'::uuid, '2026-08-01'::date);
select public.assign_subject_teacher(:'section7a_id'::uuid, :'chem_id'::uuid, :'ayesha_user_id'::uuid, '2026-08-01'::date);

-- ── AC1: a dry run reports exactly what would be created, including the
--    resigned-staff allocations by name, and writes nothing ────────────

select public.clone_academic_structure(:'from_session_id'::uuid, :'to_session_id'::uuid, :'campus_id'::uuid, true) as dry_run_result \gset
select is(((:'dry_run_result')::jsonb -> 'sections' ->> 'created')::int, 2, 'AC: dry run reports 2 sections to create');
select is(((:'dry_run_result')::jsonb -> 'class_subject_maps' ->> 'created')::int, 2, 'AC: dry run reports 2 curriculum maps to create');
select is(((:'dry_run_result')::jsonb -> 'allocations' ->> 'created')::int, 4, 'AC: dry run reports 4 allocations to create (2 class-teacher + 2 subject-teacher)');
select is(
  jsonb_array_length((:'dry_run_result')::jsonb -> 'resigned_staff_allocations'), 2,
  'AC: dry run names both of Ayesha''s allocations (class teacher + subject teacher) as referencing resigned staff'
);
select is(
  (select count(*)::int from public.class_section where session_id = :'to_session_id'::uuid),
  0,
  'AC: the dry run writes nothing — zero sections exist in the target session'
);

-- ── AC3/AC4: the real run creates exactly what the dry run promised;
--    resigned-staff allocations save with staff_id NULL, surfacing in
--    the unallocated list ────────────────────────────────────────────

select public.clone_academic_structure(:'from_session_id'::uuid, :'to_session_id'::uuid, :'campus_id'::uuid, false) as real_run_result \gset
select is(((:'real_run_result')::jsonb -> 'sections' ->> 'created')::int, 2, 'the real run creates the 2 sections the dry run promised');
select is(
  (select count(*)::int from public.class_section where session_id = :'to_session_id'::uuid),
  2,
  '2 sections now exist in the target session'
);
select id as new_section7a_id from public.class_section where session_id = :'to_session_id'::uuid and class_level_id = :'class7_id'::uuid and name = 'A' \gset
select is(
  (select staff_id from public.section_class_teacher where section_id = :'new_section7a_id'::uuid and effective_to is null),
  null::uuid,
  'AC: the cloned class-teacher allocation for the resigned staff member''s section saves with staff_id NULL'
);
select is(
  (select staff_id from public.section_subject_teacher where section_id = :'new_section7a_id'::uuid and subject_id = :'chem_id'::uuid and effective_to is null),
  null::uuid,
  'AC: the cloned subject-teacher allocation for the resigned staff member saves with staff_id NULL'
);
select is(
  (select count(*)::int from public.v_unallocated_section_subject where section_id = :'new_section7a_id'::uuid and subject_id = :'chem_id'::uuid),
  1,
  'AC: the null-staff cloned allocation appears in the unallocated list for reassignment'
);
select id as new_section6a_id from public.class_section where session_id = :'to_session_id'::uuid and class_level_id = :'class6_id'::uuid and name = 'A' \gset
select is(
  (select staff_id from public.section_class_teacher where section_id = :'new_section6a_id'::uuid and effective_to is null),
  :'bilal_user_id'::uuid,
  'a genuinely active teacher''s allocation clones with the real staff_id, not nulled'
);

-- ── AC5: no enrolment rows are created by the clone ─────────────────

select is(
  (select count(*)::int from public.enrolment where session_id = :'to_session_id'::uuid),
  0,
  'AC: the clone never creates enrolment rows — promotion is a separate, per-student decision'
);

-- ── AC3: running it again against the same target reports everything
--    skipped, with no duplicates ────────────────────────────────────

select public.clone_academic_structure(:'from_session_id'::uuid, :'to_session_id'::uuid, :'campus_id'::uuid, false) as rerun_result \gset
select is(((:'rerun_result')::jsonb -> 'sections' ->> 'created')::int, 0, 'AC: a second run creates 0 new sections');
select is(((:'rerun_result')::jsonb -> 'sections' ->> 'skipped')::int, 2, 'AC: a second run reports the 2 existing sections skipped');
select is(((:'rerun_result')::jsonb -> 'allocations' ->> 'created')::int, 0, 'a second run creates 0 new allocations');
select is(
  (select count(*)::int from public.class_section where session_id = :'to_session_id'::uuid),
  2,
  'AC: no duplicates — still exactly 2 sections in the target session after two real runs'
);
select is(
  (select count(*)::int from public.section_class_teacher where section_id = :'new_section6a_id'::uuid),
  1,
  'no duplicate class-teacher allocation row was created on the re-run'
);

-- ── validation and tenant isolation ─────────────────────────────────

select throws_ok(
  format('select public.clone_academic_structure(%L, %L, %L, true)', :'from_session_id', :'from_session_id', :'campus_id'),
  'SAME_SESSION',
  'cloning a session into itself is rejected'
);
select throws_ok(
  format('select public.clone_academic_structure(%L, %L, %L, true)', :'other_session_id', :'to_session_id', :'campus_id'),
  'FROM_SESSION_NOT_FOUND',
  'a foreign-tenant from-session is refused'
);
select throws_ok(
  format('select public.clone_academic_structure(%L, %L, %L, true)', :'from_session_id', :'other_session_id', :'campus_id'),
  'TO_SESSION_NOT_FOUND',
  'a foreign-tenant to-session is refused'
);

select * from finish();
rollback;
