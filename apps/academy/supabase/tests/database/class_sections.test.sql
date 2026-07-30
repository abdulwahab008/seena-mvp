-- pgTAP tests for FR-E02: class_section creation (campus-scoped uniqueness,
-- capacity bounds) and the class_level DELETE guard it unblocks.
begin;
select plan(9);

select public.provision_tenant('test-section-co', 'Section Co', 'owner@sectionco.test');
select id as tenant_id from public.tenant where slug = 'test-section-co' \gset
select id as campus_north from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

-- 'owner' throughout (not 'principal'): create_campus is owner/super_admin
-- only, and owner is also allowed to create sections and delete class
-- levels, so one role covers this whole test without role-switching churn.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_north'))::text,
  true
);

-- A second campus, so the "scoped to campus, not tenant" AC is testable.
select public.create_campus('SOUTH', 'Campus South', null) as _unused \gset
select id as campus_south from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_north', :'campus_south')
  )::text,
  true
);

select lives_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'A', p_capacity => 40) $$,
    :'campus_north', :'session_id', :'class9_id'
  ),
  'creating section A for class 9 at Campus North succeeds'
);
select lives_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'B', p_capacity => 40) $$,
    :'campus_north', :'session_id', :'class9_id'
  ),
  'creating a second, differently-named section for the same triple succeeds'
);
select is(
  (select count(*)::int from public.class_section where campus_id = :'campus_north'),
  2,
  'both sections exist as class_section rows'
);

select throws_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'A', p_capacity => 35) $$,
    :'campus_north', :'session_id', :'class9_id'
  ),
  'SECTION_NAME_DUPLICATE',
  'a second section named A for the same class/campus/session is rejected'
);

-- Uniqueness is scoped to campus: 'A' at South succeeds even though 'A'
-- already exists at North for the same class level and session.
select lives_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'A', p_capacity => 40) $$,
    :'campus_south', :'session_id', :'class9_id'
  ),
  'section A at Campus South succeeds despite section A already existing at Campus North'
);

select throws_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'C', p_capacity => 0) $$,
    :'campus_north', :'session_id', :'class9_id'
  ),
  'CAPACITY_OUT_OF_RANGE',
  'a capacity of 0 is rejected'
);
select throws_ok(
  format(
    $$ select public.create_section(p_campus_id => %L, p_session_id => %L, p_class_level_id => %L, p_name => 'C', p_capacity => 250) $$,
    :'campus_north', :'session_id', :'class9_id'
  ),
  'CAPACITY_OUT_OF_RANGE',
  'a capacity of 250 is rejected'
);

-- ── class_level DELETE, now guarded by real section usage ─────────────

select throws_ok(
  format('select public.delete_class_level(%L)', :'class9_id'),
  'CLASS_LEVEL_IN_USE',
  'deleting a class level with sections against it is rejected'
);

select id as class8_id from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset
select lives_ok(
  format('select public.delete_class_level(%L)', :'class8_id'),
  'deleting an unused class level succeeds'
);

select * from finish();
rollback;
