begin;
select plan(5);

select public.provision_tenant('test-fee-class', 'Fee Class Co', 'owner@feeclass.test');
select id as tenant_id from public.tenant where slug = 'test-fee-class' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@feeclass.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@feeclass.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Fee Kid', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
reset role;
insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, direction, amount_paisa, value_date) values
  (:'tenant_id', :'campus_id', :'e1', :'session_id', 'charge', 'debit', 500000, '2026-09-01'),
  (:'tenant_id', :'campus_id', :'e1', :'session_id', 'concession', 'credit', 50000, '2026-09-01'),
  (:'tenant_id', :'campus_id', :'e1', :'session_id', 'payment', 'credit', 300000, '2026-09-10'),
  (:'tenant_id', :'campus_id', :'e1', :'session_id', 'charge', 'debit', 500000, '2026-10-01');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select billed_paisa from public.fee_class_report('2026-09-01', '2026-09-30') where class_level_id = :'class1_id'), 500000::bigint, 'September billing for the class');
select is((select collected_paisa from public.fee_class_report('2026-09-01', '2026-09-30') where class_level_id = :'class1_id'), 300000::bigint, 'September collection');
select is((select concession_paisa from public.fee_class_report('2026-09-01', '2026-09-30') where class_level_id = :'class1_id'), 50000::bigint, 'September concession');
select is((select balance_paisa from public.fee_class_report('2026-09-01', '2026-10-31') where class_level_id = :'class1_id'), 650000::bigint, 'balance owed by the end of October');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select coalesce(sum(billed_paisa), 0) from public.fee_class_report('2026-09-01', '2026-10-31')), 0::numeric, 'a teacher sees no fee figures');

select * from finish();
rollback;
