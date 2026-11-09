begin;
select plan(5);

select public.provision_tenant('test-decide-leave', 'Decide Leave Co', 'owner@decideleave.test');
select id as tenant_id from public.tenant where slug = 'test-decide-leave' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as office_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@decideleave.test', 'authenticated', 'authenticated', 'x'), (:'office_uid', 'r@decideleave.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@decideleave.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'office_uid', :'tenant_id', 'receptionist', 'Front Desk'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Leave Kid', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
reset role;
insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category)
select :'tenant_id', :'campus_id', :'session_id', :'e1', :'owner_uid', 'office', current_date + 1, current_date + 2, (enum_range(null::public.student_leave_category))[1]
returning id as leave_id \gset
insert into public.student_leave_application (tenant_id, campus_id, session_id, enrolment_id, applied_by_user_id, applied_via, from_date, to_date, reason_category)
select :'tenant_id', :'campus_id', :'session_id', :'e1', :'owner_uid', 'office', current_date + 10, current_date + 10, (enum_range(null::public.student_leave_category))[1]
returning id as leave2_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.decide_student_leave(%L, true) $$, :'leave_id'), '42501', 'FORBIDDEN', 'a subject teacher cannot decide leave');

select set_config('request.jwt.claims', json_build_object('sub', :'office_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.decide_student_leave(%L, true, 'Get well soon') $$, :'leave_id'), 'the front desk approves a leave');
select is((select status::text || '|' || decision_note from public.student_leave_application where id = :'leave_id'), 'approved|Get well soon', 'it is approved with the note');
select throws_ok(format($$ select public.decide_student_leave(%L, false) $$, :'leave_id'), '55000', 'LEAVE_NOT_PENDING', 'a decided leave cannot be decided again');
select public.decide_student_leave(:'leave2_id', false);
select is((select status::text from public.student_leave_application where id = :'leave2_id'), 'rejected', 'a leave can be rejected');

select * from finish();
rollback;
