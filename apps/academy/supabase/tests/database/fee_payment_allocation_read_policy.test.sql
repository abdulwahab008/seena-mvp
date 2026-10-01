-- pgTAP: fee_payment_allocation_read (rewritten as a correlated EXISTS so it does not seq-scan
-- fee_payment). The rewrite must keep the exact visibility: own-tenant owner sees the allocations,
-- a campus-scoped role sees only its campuses, another tenant sees nothing.
begin;
select plan(5);

select public.provision_tenant('test-alloc-policy-a', 'Alloc Policy A', 'owner@allocpolicya.test');
select public.provision_tenant('test-alloc-policy-b', 'Alloc Policy B', 'owner@allocpolicyb.test');
select id as tenant_a from public.tenant where slug = 'test-alloc-policy-a' \gset
select id as tenant_b from public.tenant where slug = 'test-alloc-policy-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_a' \gset
select id as class1_a from public.class_level where tenant_id = :'tenant_a' and code = '1' \gset

select
  (date_trunc('month', current_date))::date as month1 \gset

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_a', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_a' and code <> '1';
select public.create_section(:'campus_a'::uuid, :'session_a'::uuid, :'class1_a'::uuid, 'A', 20) as section_a \gset
select public.seed_default_fee_heads(:'tenant_a'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_a' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_a'::uuid, :'session_a'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_a'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_a'::uuid, 'Alloc Child', '2015-01-01'::date, 'male') as student_a \gset
select public.enrol_student(:'section_a'::uuid, :'student_a'::uuid) as enrol_a \gset
select public.generate_challans(:'campus_a'::uuid, :'session_a'::uuid, :'month1'::date, false) as gen \gset
select public.record_payment(:'enrol_a'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode) as payment_a \gset

select is((select count(*)::int from public.fee_payment_allocation where payment_id = :'payment_a'), 1,
  'the owner of the tenant sees the allocation of its own payment');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_a', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.fee_payment_allocation where payment_id = :'payment_a'), 1,
  'a campus-scoped role sees the allocation for a payment in its campus');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_a', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from public.fee_payment_allocation where payment_id = :'payment_a'), 0,
  'a campus-scoped role with other campuses sees no allocation');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_b', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from public.fee_payment_allocation where payment_id = :'payment_a'), 0,
  'the owner of another tenant sees no allocation');

select is(
  (select count(*)::int from pg_policies where tablename = 'fee_payment_allocation' and policyname = 'fee_payment_allocation_read' and qual ilike '%exists (%'),
  1,
  'the read policy is the correlated EXISTS form (no hashed uncorrelated sub-select)');

select * from finish();
rollback;
