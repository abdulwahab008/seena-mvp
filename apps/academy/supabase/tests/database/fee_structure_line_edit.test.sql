-- pgTAP tests: draft fee structure lines can be set for a class range, edited and deleted; published ones cannot.
begin;
select plan(12);

select public.provision_tenant('test-fee-line-edit', 'Fee Line Edit Co', 'owner@feelineedit.test');
select id as tenant_id from public.tenant where slug = 'test-fee-line-edit' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select id as class2_id from public.class_level where tenant_id = :'tenant_id' and code = '2' \gset
select id as class3_id from public.class_level where tenant_id = :'tenant_id' and code = '3' \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'o@feelineedit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Line Edit Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset

select is(
  public.set_structure_lines(:'structure_id'::uuid, array[:'class1_id', :'class2_id']::uuid[], :'tuition_id'::uuid, 300000::bigint, 'monthly'),
  '{"added": 2, "updated": 0}'::jsonb,
  'a class range adds one line per class'
);
select is(
  public.set_structure_lines(:'structure_id'::uuid, array[:'class2_id', :'class3_id']::uuid[], :'tuition_id'::uuid, 500000::bigint, 'monthly'),
  '{"added": 1, "updated": 1}'::jsonb,
  'a class that already has the fee head is updated, not rejected'
);
select is(
  (select amount_paisa from public.fee_structure_line where structure_id = :'structure_id' and class_id = :'class2_id'),
  500000::bigint,
  'the updated class takes the new amount'
);
select is(
  (select amount_paisa from public.fee_structure_line where structure_id = :'structure_id' and class_id = :'class1_id'),
  300000::bigint,
  'a class outside the new range keeps its amount'
);
select throws_ok(
  format('select public.set_structure_lines(%L, %L::uuid[], %L, 1, %L)', :'structure_id', '{}', :'tuition_id', 'monthly'),
  'CLASSES_REQUIRED', 'an empty class range is rejected'
);

select id as line1_id from public.fee_structure_line where structure_id = :'structure_id' and class_id = :'class1_id' \gset
select lives_ok(
  format('select public.update_structure_line(%L, 450000, %L, 8::smallint)', :'line1_id', 'one_time'),
  'a draft line can change amount, frequency and months'
);
select results_eq(
  format('select amount_paisa, frequency::text, billing_month_mask::int from public.fee_structure_line where id = %L', :'line1_id'),
  $$values (450000::bigint, 'one_time', 8)$$,
  'the line holds the edited values'
);
select lives_ok(format('select public.remove_structure_line(%L)', :'line1_id'), 'a draft line can be deleted');
select is((select count(*)::int from public.fee_structure_line where id = :'line1_id'), 0, 'the deleted line is gone');

select id as line2_id from public.fee_structure_line where structure_id = :'structure_id' and class_id = :'class2_id' \gset
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code not in ('2', '3');
select public.publish_fee_structure(:'structure_id'::uuid);
select throws_ok(format('select public.remove_structure_line(%L)', :'line2_id'), 'STRUCTURE_NOT_DRAFT', 'a published line cannot be deleted');
select throws_ok(
  format('select public.update_structure_line(%L, 1, %L, 4095::smallint)', :'line2_id', 'monthly'),
  'STRUCTURE_NOT_DRAFT', 'a published line cannot be edited'
);

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'teacher',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.remove_structure_line(%L)', :'line2_id'), 'FORBIDDEN', 'a teacher cannot change the fee structure');

select * from finish();
rollback;
