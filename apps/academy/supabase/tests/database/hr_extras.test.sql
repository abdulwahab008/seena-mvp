begin;
select plan(12);

select public.provision_tenant('test-hr-extras', 'HR Extras Co', 'owner@hrextras.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.department (tenant_id, code, name_en) values (:'tenant_id', 'SCI', 'Science') returning id as dept_id \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'hr@hrextras.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'hr_manager', 'HR Manager');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name, dob, doj, department_id, cnic_expires_on)
values (:'tenant_id', :'campus_id', 'E-1', '35201-1111111-1', 'female', 'Ms Amna', make_date(1990, extract(month from current_date)::int, 1), current_date - 400, :'dept_id', current_date + 20);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_job_opening(:'campus_id'::uuid, 'Physics teacher', :'dept_id'::uuid, 1::smallint, null::text, null::text, null::date) as opening_id \gset
select public.add_job_application(:'opening_id'::uuid, 'Sana Iqbal', '03001234567', null::text, '35202-2222222-2', 'MSc Physics', 4::numeric, 'Referral') as app_id \gset

select public.save_interview_score(:'app_id', 4::smallint, 5::smallint, 4::smallint, 5::smallint, 'hire', 'Strong demo');
select public.save_interview_score(:'app_id', 5::smallint, 5::smallint, 4::smallint, 5::smallint, 'hire', 'Even better on review');
select is((select count(*)::int || ' ' || max(subject_knowledge) from public.interview_score), '1 5', 'one scorecard per interviewer, updated in place');
select throws_ok(format($$ select public.save_interview_score(%L, 6::smallint, 1::smallint, 1::smallint, 1::smallint, 'hire') $$, :'app_id'), '23514', null, 'scores are 1 to 5');

select throws_ok(format($$ select public.hire_applicant(%L, 'E-2', 'female') $$, :'app_id'), '55000', 'NOT_OFFERED', 'an offer comes before hiring');
select public.make_job_offer(:'app_id', 9000000, current_date + 14);
select is((select stage || ' ' || offer_salary_paisa from public.job_application where id = :'app_id'), 'offered 9000000', 'the offer is recorded');
select public.hire_applicant(:'app_id', 'E-2', 'female') as staff_id \gset
reset role;
select is((select full_name || ' ' || doj || ' ' || (department_id = :'dept_id')::text from public.staff where id = :'staff_id'),
  'Sana Iqbal ' || (current_date + 14) || ' true', 'hiring creates the staff record on the offered date and department');
select is((select stage from public.job_application where id = :'app_id'), 'hired', 'and closes the application');
select is((select cnic from public.staff where id = :'staff_id'), '35202-2222222-2', 'carrying the CNIC');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.hr_dashboard() as dash \gset
select is((:'dash'::jsonb ->> 'headcount')::int, 2, 'the dashboard counts staff');
select is((:'dash'::jsonb -> 'cnic_expiring' -> 0 ->> 'name'), 'Ms Amna', 'and lists CNICs expiring soon');
select is((:'dash'::jsonb -> 'birthdays' -> 0 ->> 'day')::int, 1, 'and this month''s birthdays by day only');

select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.hr_dashboard() $$, '42501', 'FORBIDDEN', 'the accountant cannot open the HR dashboard');
select is((select count(*)::int from public.interview_score), 0, 'or read scorecards');

select * from finish();
rollback;
