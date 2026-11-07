begin;
select plan(6);

select public.provision_tenant('test-incident-co', 'Incident Co', 'owner@incident.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'DHA', 'DHA') returning id as dha_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 't@incident.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'owner', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_student(:'campus_id'::uuid, 'Naughty Kid', '2014-01-01'::date, 'male') as kid \gset

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.record_student_incident(%L, current_date, 'behaviour', 'minor', 'Talking in assembly', 'Warned', true) $$, :'kid'), 'a class teacher records an incident');
select is((select count(*)::int from public.student_incident where student_id = :'kid'), 1, 'it is on the student''s record');
select throws_ok(format($$ select public.record_student_incident(%L, current_date + 1, 'behaviour', 'minor', 'x') $$, :'kid'), '22023', 'DATE_INVALID', 'an incident cannot be in the future');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'dha_id'))::text, true);
select throws_ok(format($$ select public.record_student_incident(%L, current_date, 'behaviour', 'minor', 'x') $$, :'kid'), '42501', 'FORBIDDEN', 'a teacher on another campus cannot write it');
select is((select count(*)::int from public.student_incident), 0, 'or read it');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.student_incident), 0, 'parents never see the log');

select * from finish();
rollback;
