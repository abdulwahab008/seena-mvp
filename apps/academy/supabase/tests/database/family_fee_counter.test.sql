begin;
select plan(10);

select public.provision_tenant('test-family-fee-co', 'Family Fee Co', 'owner@familyfee.test');
select id as tenant_id from public.tenant where slug = 'test-family-fee-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'owner_uid', 'owner@family-fixture.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Family Fixture Owner');

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_cash_counter(:'campus_id'::uuid, 'Main desk') as ctr1 \gset
select public.open_counter_session(:'ctr1'::uuid, 0);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Elder Sibling', '2014-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Younger Sibling', '2016-01-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.link_family_group(array[:'s1'::uuid, :'s2'::uuid]) as family_id \gset

reset role;
select family_no from public.family_group where id = :'family_id' \gset
select ok(:family_no >= 1, 'a new family gets a family number');
select gr_number as s2_gr from public.student where id = :'s2' \gset
set local role authenticated;

select is((select count(*)::int from public.family_fee_lookup(:'family_no')), 2, 'the family is found by its number, with both children');
select is((select count(*)::int from public.family_fee_lookup(:'s2_gr')), 2, 'the family is found by a child''s GR number');
select is((select sum(balance_paisa) from public.family_fee_lookup(:'family_no'))::bigint, 1000000::bigint, 'the family owes both children''s fees');

select throws_ok(format($$ select public.collect_family_payment(%L, 2000000, 'fam-key-0') $$, :'family_id'), '22023', 'AMOUNT_EXCEEDS_DUES', 'more than the family owes is refused');

select public.collect_family_payment(:'family_id'::uuid, 700000::bigint, 'fam-key-1') as paid \gset
select is(jsonb_array_length(:'paid'::jsonb -> 'receipts'), 2, 'one payment is split into a receipt per child');
select is(public.student_balance(:'e1'::uuid) + public.student_balance(:'e2'::uuid), 300000::bigint, 'the family balance drops by the amount paid');

select public.collect_family_payment(:'family_id'::uuid, 700000::bigint, 'fam-key-1') as replay \gset
select is((select bool_and((r ->> 'is_replay')::boolean) from jsonb_array_elements(:'replay'::jsonb -> 'receipts') r), true, 'a retried submit returns the original receipts');
select is(public.student_balance(:'e1'::uuid) + public.student_balance(:'e2'::uuid), 300000::bigint, 'and charges nothing twice');

select set_config('request.jwt.claims',
  json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.family_fee_lookup(%L) $$, :'family_no'), '42501', 'FORBIDDEN', 'a teacher cannot look up family dues');

select * from finish();
rollback;
