-- pgTAP tests: one fee change applied to many students' fee plan lines, approved now or later; all or nothing.
begin;
select plan(9);

select public.provision_tenant('test-bulk-fee', 'Bulk Fee Co', 'owner@bulkfee.test');
select id as tenant_id from public.tenant where slug = 'test-bulk-fee' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid, gen_random_uuid() as accountant_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@bulkfee.test', 'authenticated', 'authenticated', 'x'),
  (:'accountant_uid', 'a@bulkfee.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Bulk Owner'),
  (:'accountant_uid', :'tenant_id', 'accountant', 'Bulk Accountant');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.enrol_student(:'section_id'::uuid, public.create_student(:'campus_id'::uuid, 'Kid ' || n, '2015-01-01'::date, 'male'))
  from generate_series(1, 3) n;

select array_agg(fpl.id order by s.name_en) as lines
  from public.fee_plan_line fpl
  join public.fee_plan fp on fp.id = fpl.plan_id
  join public.enrolment e on e.id = fp.enrolment_id
  join public.student s on s.id = e.student_id
 where s.tenant_id = :'tenant_id' \gset
select (:'lines'::uuid[])[1:2] as two \gset

select is(public.bulk_propose_fee_plan_override(:'two'::uuid[], 250000, 'Staff children', true), 2, 'an owner changes two students at once');
select is(
  (select array_agg(amount_paisa order by amount_paisa) from public.fee_plan_line where id = any(:'lines'::uuid[])),
  array[250000, 250000, 500000]::bigint[],
  'approved now: the two selected students pay the new fee, the third is untouched'
);

select set_config('request.jwt.claims', json_build_object('sub', :'accountant_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(
  format('select public.bulk_propose_fee_plan_override(%L::uuid[], 100000, %L, true)', :'lines', 'Scholarship'),
  'FORBIDDEN', 'an accountant cannot approve their own change'
);
select is(
  (select count(*)::int from public.fee_plan_line where id = any(:'lines'::uuid[]) and override_status = 'pending_approval'),
  0, 'a failed bulk change leaves every line as it was'
);
select is(public.bulk_propose_fee_plan_override(:'lines'::uuid[], 100000, 'Scholarship'), 3, 'an accountant sends a change for approval');
select is(
  (select count(*)::int from public.fee_plan_line where id = any(:'lines'::uuid[]) and override_status = 'pending_approval' and pending_amount_paisa = 100000),
  3, 'every selected line waits for approval'
);
select throws_ok(
  format('select public.bulk_propose_fee_plan_override(%L::uuid[], 100000, %L)', :'lines', ' '),
  'REASON_REQUIRED', 'a reason is required'
);

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.bulk_decide_fee_plan_override(:'lines'::uuid[], true), 3, 'an owner approves them together');
select is(
  (select array_agg(distinct amount_paisa) from public.fee_plan_line where id = any(:'lines'::uuid[])),
  array[100000]::bigint[],
  'the approved fee is live for all three'
);

select * from finish();
rollback;
