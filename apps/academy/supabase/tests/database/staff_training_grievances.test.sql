begin;
select plan(10);

select public.provision_tenant('test-cpd-co', 'CPD Co', 'owner@cpd.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as t_uid \gset
select gen_random_uuid() as p_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'hr@cpd.test', 'authenticated', 'authenticated', 'x'),
  (:'t_uid', 't@cpd.test', 'authenticated', 'authenticated', 'x'),
  (:'p_uid', 'p@cpd.test', 'authenticated', 'authenticated', 'x');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name, user_id)
values (:'tenant_id', :'campus_id', 'E1', '35202-1111111-1', 'female', 'Teacher One', :'t_uid') returning id as t_staff \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
values (:'tenant_id', :'campus_id', 'E2', '35202-2222222-2', 'male', 'Teacher Two') returning id as t2_staff \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_training_program(:'campus_id', 'Child safeguarding', 'In-house', current_date, 6, true, array[:'t_staff'::uuid]) as prog \gset
select public.save_training_program(:'campus_id', 'Phonics workshop', 'British Council', current_date, 4, false, array[:'t_staff'::uuid, :'t2_staff'::uuid]);
select is((select hours from public.staff_cpd_hours(:'campus_id', extract(year from current_date)::int) where staff_id = :'t_staff'), 10.0, 'CPD hours add up across programs');
select is((select mandatory_missed from public.staff_cpd_hours(:'campus_id', extract(year from current_date)::int) where staff_id = :'t2_staff'), 1, 'a missed mandatory program is counted');

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_training_program(%L, 'X', null, current_date, 1, false, '{}') $$, :'campus_id'), '42501', 'FORBIDDEN', 'a teacher cannot record training');
select is((select count(*)::int from public.training_attendance), 2, 'a teacher sees only their own attendance');
select public.raise_staff_grievance('workload', 'Too many periods', 'I have 38 periods a week') as g \gset
select is((select count(*)::int from public.staff_grievance), 1, 'a teacher sees their own grievance');

select set_config('request.jwt.claims', json_build_object('sub', :'p_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.staff_grievance), 0, 'a principal cannot read staff grievances');
select throws_ok(format($$ select public.handle_staff_grievance(%L, 'resolved', 'x') $$, :'g'), '42501', 'FORBIDDEN', 'or handle them');

select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.handle_staff_grievance(%L, 'resolved') $$, :'g'), '22023', 'RESOLUTION_REQUIRED', 'resolving needs a written outcome');
select lives_ok(format($$ select public.handle_staff_grievance(%L, 'resolved', 'Timetable rebalanced to 32 periods') $$, :'g'), 'HR resolves the grievance');

select set_config('request.jwt.claims', json_build_object('sub', :'t_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select resolution from public.staff_grievance where id = :'g'), 'Timetable rebalanced to 32 periods', 'the teacher sees the outcome');

select * from finish();
rollback;
