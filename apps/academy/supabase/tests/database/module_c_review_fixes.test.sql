-- pgTAP tests for the Module C independent-review fixes
-- (20260731220000_module_c_review_fixes.sql).
begin;
select plan(8);

select public.provision_tenant('test-c-review-fix-co', 'C Review Fix Co', 'owner@creviewfixco.test');
select id as tenant_id from public.tenant where slug = 'test-c-review-fix-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-c-review-fix-other-co', 'C Review Fix Other Co', 'owner@creviewfixotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-c-review-fix-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select id as other_class1_id from public.class_level where tenant_id = :'other_tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select public.create_section(:'other_campus_id'::uuid, :'other_session_id'::uuid, :'other_class1_id'::uuid, 'A', 20) as other_section_id \gset
select public.create_student(:'other_campus_id'::uuid, 'Other Tenant Child', '2015-01-01'::date, 'male') as other_student_id \gset
select public.enrol_student(:'other_section_id'::uuid, :'other_student_id'::uuid) as other_enrol_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Own Child', '2015-01-01'::date, 'male') as own_student_id \gset
select public.enrol_student(:'section_id'::uuid, :'own_student_id'::uuid) as own_enrol_id \gset

-- ── fix #2: create_student() rejects a foreign-tenant campus_id ────────

select throws_ok(
  format('select public.create_student(%L, ''Cross Tenant Child'', ''2015-01-01''::date, ''male'')', :'other_campus_id'),
  'CAMPUS_NOT_FOUND',
  'create_student() refuses a campus_id belonging to a different tenant, protecting the foreign gr_sequence'
);

-- ── fix #3: fn_assign_section() rejects a foreign-tenant section_id ────

select throws_ok(
  format('select public.fn_assign_section(%L, %L)', :'own_enrol_id', :'other_section_id'),
  'SECTION_NOT_FOUND',
  'fn_assign_section() refuses a section_id belonging to a different tenant, protecting its real seat capacity'
);

-- the legitimate same-tenant path still works
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 20) as section_b_id \gset
select public.fn_assign_section(:'own_enrol_id'::uuid, :'section_b_id'::uuid);
select is(
  (select section_id from public.enrolment where id = :'own_enrol_id'),
  :'section_b_id'::uuid,
  'the fix does not regress an ordinary, same-tenant section reassignment'
);

-- ── fix #1: link_family_group() rejects a foreign-tenant student id ────

select throws_ok(
  format('select public.link_family_group(array[%L, %L]::uuid[])', :'own_student_id', :'other_student_id'),
  'STUDENT_NOT_FOUND',
  'link_family_group() refuses a batch containing a foreign-tenant student id, before it can leak that tenant''s real group'
);

select public.create_student(:'campus_id'::uuid, 'Own Sibling', '2016-01-01'::date, 'female') as own_sibling_id \gset
select public.link_family_group(array[:'own_student_id', :'own_sibling_id']::uuid[]) as group_id \gset
select is(
  (select count(distinct family_group_id)::int from public.student where id in (:'own_student_id', :'own_sibling_id')),
  1,
  'the fix does not regress an ordinary, same-tenant family group link'
);

-- ── fix #1b: fn_merge_family_groups() rejects a foreign-tenant group id ─

reset role;
select public.provision_tenant('test-c-review-fix-third-co', 'C Review Fix Third Co', 'owner@creviewfixthirdco.test');
select id as third_tenant_id from public.tenant where slug = 'test-c-review-fix-third-co' \gset
select id as third_campus_id from public.campus where tenant_id = :'third_tenant_id' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'third_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'third_campus_id'))::text,
  true
);
select public.create_student(:'third_campus_id'::uuid, 'Third Tenant Solo', '2015-01-01'::date, 'male') as third_student_id \gset
select public.link_family_group(array[:'third_student_id']::uuid[]) as third_group_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.fn_merge_family_groups(%L, %L)', :'group_id', :'third_group_id'),
  'FAMILY_GROUP_NOT_FOUND',
  'fn_merge_family_groups() refuses a p_merge_id belonging to a different tenant'
);
select throws_ok(
  format('select public.fn_merge_family_groups(%L, %L)', :'third_group_id', :'group_id'),
  'FAMILY_GROUP_NOT_FOUND',
  'fn_merge_family_groups() refuses a p_keep_id belonging to a different tenant'
);

-- ── fix #4: fn_assign_next_roll_no() still assigns sequentially (lock
--    added does not change the single-connection outcome) ─────────────

select public.create_student(:'campus_id'::uuid, 'Roll Test Child', '2017-01-01'::date, 'female') as roll_student_id \gset
select public.enrol_student(:'section_b_id'::uuid, :'roll_student_id'::uuid) as roll_enrol_id \gset
select is(
  public.fn_assign_next_roll_no(:'roll_enrol_id'::uuid),
  1,
  'the advisory lock does not regress ordinary sequential roll number assignment'
);

select * from finish();
rollback;
