-- pgTAP tests for FR-E01: class_level catalogue, seeding, and mutation
-- functions (create/deactivate/swap-ordinal).
begin;
select plan(11);

select public.provision_tenant('test-classlevel-co', 'Class Level Co', 'owner@classlevelco.test');
select id as tenant_id from public.tenant where slug = 'test-classlevel-co' \gset

select is(
  (select count(*)::int from public.class_level where tenant_id = :'tenant_id'),
  14,
  'provisioning seeds exactly 14 class levels'
);
select is(
  (select code from public.class_level where tenant_id = :'tenant_id' and ordinal = 0),
  'NUR',
  'Nursery is ordinal 0'
);
select is(
  (select code from public.class_level where tenant_id = :'tenant_id' and ordinal = 1),
  'KG',
  'Kindergarten is ordinal 1'
);
select is(
  (select code from public.class_level where tenant_id = :'tenant_id' and ordinal = 13),
  '12',
  'Class 12 is the highest ordinal (13)'
);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal')::text, true);

-- Playgroup at ordinal -1 sorts before Nursery.
select public.create_class_level('PG', 'Playgroup', null, (-1)::smallint, 'pre_primary');
select is(
  (select count(*)::int from public.class_level where tenant_id = :'tenant_id' and ordinal < 0),
  1,
  'Playgroup can be added at ordinal -1, sorting before Nursery'
);
select throws_like(
  $$ select public.create_class_level('PG2', 'Playgroup 2', null, (-1)::smallint, 'pre_primary') $$,
  '%uq_class_level_tenant_ordinal%',
  'a second class level at the same ordinal is rejected'
);

-- Swap ordinals 2 and 3 (Class 1 and Class 2) — verify it lands correctly
-- and produces an audit trail (reusing FR-A14's trigger).
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class2_id from public.class_level where tenant_id = :'tenant_id' and code = '2' \gset

select lives_ok(
  format('select public.swap_class_level_ordinals(%L, %L)', :'class1_id', :'class2_id'),
  'swapping two class levels'' ordinals succeeds atomically'
);
select is(
  (select ordinal from public.class_level where id = :'class1_id'),
  3::smallint,
  'Class 1 now holds Class 2''s old ordinal'
);
select is(
  (select ordinal from public.class_level where id = :'class2_id'),
  2::smallint,
  'Class 2 now holds Class 1''s old ordinal'
);
select is(
  (select count(*)::int from public.audit_log where table_name = 'class_level' and row_id = :'class1_id'::uuid and action = 'update'),
  1,
  'the ordinal swap produced an audit row for the class level it touched'
);

-- Deactivation, not deletion, is the only removal path.
select public.set_class_level_active(:'class1_id', false);
select is(
  (select is_active from public.class_level where id = :'class1_id'),
  false,
  'set_class_level_active can deactivate a class level (no DELETE path exists at all)'
);

select * from finish();
rollback;
