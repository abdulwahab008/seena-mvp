begin;
select plan(4);

select public.provision_tenant('test-absentees-co', 'Absentees Co', 'owner@absentees.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'o@absentees.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'uid', :'tenant_id', 'owner', 'Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as sec \gset
select public.create_student(:'campus_id'::uuid, 'Away Kid', '2016-01-01'::date, 'male') as k1 \gset
select public.create_student(:'campus_id'::uuid, 'Back Kid', '2016-01-01'::date, 'female') as k2 \gset
select public.enrol_student(:'sec'::uuid, :'k1'::uuid) as e1 \gset
select public.enrol_student(:'sec'::uuid, :'k2'::uuid) as e2 \gset

reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
select :'tenant_id', :'campus_id', :'session_id', :'sec', :'e1', current_date - d, case when d <= 4 then 'absent' else 'present' end::public.student_attendance_status
  from generate_series(1, 8) d;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
select :'tenant_id', :'campus_id', :'session_id', :'sec', :'e2', current_date - d, case when d = 1 then 'present' else 'absent' end::public.student_attendance_status
  from generate_series(1, 8) d;
set local role authenticated;

select is((select count(*)::int from public.consecutive_absentees(:'campus_id', 3)), 1, 'only the student whose latest days are absences is listed');
select is((select streak_days from public.consecutive_absentees(:'campus_id', 3)), 4, 'the streak counts the run of recent absences');
select is((select absent_since from public.consecutive_absentees(:'campus_id', 3)), current_date - 4, 'and when it started');
select is((select count(*)::int from public.consecutive_absentees(:'campus_id', 5)), 0, 'a higher threshold lists nobody');

select * from finish();
rollback;
