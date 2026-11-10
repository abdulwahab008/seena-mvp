begin;
select plan(9);

select public.provision_tenant('test-class-tests', 'Class Tests School', 'owner@classtests.test');
select id as tenant_id from public.tenant where slug = 'test-class-tests' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@classtests.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@classtests.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@classtests.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'acct_uid', :'tenant_id', 'accountant', 'Accounts');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Test Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid);
select public.create_student(:'campus_id'::uuid, 'Test Kid Two', '2015-01-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid);
select public.create_student(:'campus_id'::uuid, 'Outsider', '2015-01-01'::date, 'female') as s3 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Kid Father', p_phone_e164 => '+923001112223') as g1 \gset
select public.link_guardian(:'s1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_class_test(%L, null, 'T1', current_date, 100) $$, :'section_id'), '42501', 'FORBIDDEN', 'an accountant cannot set a class test');

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_class_test(:'section_id'::uuid, null, 'Weekly test 1', '2026-11-05'::date, 100) as test_id \gset
select is((select count(*)::int from public.class_test), 1, 'a teacher sets a class test');
select is(public.save_class_test_marks(:'test_id'::uuid, jsonb_build_array(
  jsonb_build_object('student_id', :'s1', 'marks', 100), jsonb_build_object('student_id', :'s2', 'absent', true))), 2, 'marks are saved for two students');
select is((select marks from public.class_test_mark where student_id = :'s1'), 100.00::numeric, 'full marks are kept');
select is((select absent from public.class_test_mark where student_id = :'s2'), true, 'an absence is kept');
select throws_ok(format($$ select public.save_class_test_marks(%L, '[{"student_id": "%s", "marks": 101}]') $$, :'test_id', :'s1'), '22003', 'MARKS_OUT_OF_RANGE', 'marks above the total are refused');
select throws_ok(format($$ select public.save_class_test_marks(%L, '[{"student_id": "%s", "marks": 5}]') $$, :'test_id', :'s3'), 'P0002', 'STUDENT_NOT_IN_SECTION', 'a student outside the section is refused');
select is(public.send_class_test_results(:'test_id'::uuid) ->> 'queued', '1', 'one parent with a phone is texted');
select is((select body from public.message where idempotency_key like 'class-test:%'), 'Class Tests School: Test Kid One scored 100/100 in Weekly test 1 (05 Nov).', 'the text reads naturally');

select * from finish();
rollback;
