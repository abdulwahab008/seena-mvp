begin;
select plan(8);

select public.provision_tenant('test-recruit-co', 'Recruit Co', 'owner@recruit.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'hr@recruit.test', 'authenticated', 'authenticated', 'x');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_job_opening(:'campus_id', 'Maths Teacher', null, 2::smallint, '60-80k', 'O/A level maths', current_date + 30) as job \gset
select public.add_job_application(:'job', 'Ayesha Khan', '03001234567', null, '35202-1234567-1', 'MSc Maths', 4, 'Referral') as app \gset
select is((select stage from public.job_application where id = :'app'), 'applied', 'HR adds an applicant who starts as applied');

select throws_ok(format($$ select public.move_job_application(%L, 'interview') $$, :'app'), '22023', 'INTERVIEW_TIME_REQUIRED', 'an interview needs a time');
select public.move_job_application(:'app', 'interview', 'Strong CV', now() + interval '2 days', 4::smallint);
select public.move_job_application(:'app', 'hired', 'Offer accepted');
select is((select count(*)::int from public.job_application_event where application_id = :'app'), 3, 'every move is recorded with a note');
select throws_ok(format($$ select public.move_job_application(%L, 'rejected') $$, :'app'), '22023', 'APPLICATION_CLOSED', 'a hired application cannot be moved again');
select throws_ok(format($$ select public.add_job_application(%L, 'Dup', null, null, '35202-1234567-1', null, null, null) $$, :'job'), '23505', null, 'the same CNIC cannot apply twice to one opening');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.job_application), 0, 'teachers cannot see applicants');
select throws_ok(format($$ select public.save_job_opening(%L, 'X', null, 1::smallint, null, null, null) $$, :'campus_id'), '42501', 'FORBIDDEN', 'or post openings');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.job_opening), 0, 'parents cannot see openings');

select * from finish();
rollback;
