begin;
select plan(10);

select public.provision_tenant('test-live-co', 'Live Co', 'owner@live.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as t_uid \gset
select gen_random_uuid() as s_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'t_uid', 't@live.test', 'authenticated', 'authenticated', 'x'), (:'s_uid', 's@live.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'t_uid', :'tenant_id', 'owner', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Live Kid', '2015-01-01'::date, 'male') as kid \gset
select public.enrol_student(:'sec'::uuid, :'kid'::uuid);

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.schedule_live_class(%L, 'x', now(), 40::smallint, 'http://insecure.example') $$, :'sec'), '23514', null, 'the link must be https');
select public.schedule_live_class(:'sec', 'Fractions live', now() + interval '5 minutes', 40::smallint, 'https://meet.example/abc') as live_now \gset
select public.schedule_live_class(:'sec', 'Tomorrow', now() + interval '1 day', 40::smallint, 'https://meet.example/tmr') as live_later \gset
select public.schedule_live_class(:'sec', 'Cancelled', now(), 40::smallint, 'https://meet.example/x') as live_cancel \gset
select public.cancel_live_class(:'live_cancel');

reset role;
insert into public.student_portal_account (tenant_id, campus_id, student_id, user_id, must_change_password) values (:'tenant_id', :'campus_id', :'kid', :'s_uid', false);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'s_uid', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select is((select count(*)::int from public.my_live_classes()), 3, 'the student sees their section''s classes');
select is(public.join_live_class(:'live_now'), 'https://meet.example/abc', 'joining a class about to start gives the link');
select is(public.join_live_class(:'live_now'), 'https://meet.example/abc', 'joining again is fine');
select is((select joined from public.my_live_classes() where id = :'live_now'), true, 'and the student is marked present');
select throws_ok(format($$ select public.join_live_class(%L) $$, :'live_later'), '55000', 'CLASS_NOT_OPEN', 'a class far in the future is not open yet');
select throws_ok(format($$ select public.join_live_class(%L) $$, :'live_cancel'), '55000', 'CLASS_CANCELLED', 'a cancelled class cannot be joined');
select is((select count(*)::int from public.live_class), 0, 'students cannot read the class table directly');

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.live_class_attendance), 1, 'the teacher sees one attendance row');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.cancel_live_class(%L) $$, :'live_later'), '42501', 'FORBIDDEN', 'another teacher cannot cancel it');

select * from finish();
rollback;
