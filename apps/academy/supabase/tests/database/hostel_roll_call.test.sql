begin;
select plan(5);

select public.provision_tenant('test-roll-call', 'Roll Call Co', 'owner@rollcall.test');
select id as tenant_id from public.tenant where slug = 'test-roll-call' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@rollcall.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@rollcall.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'acct_uid', :'tenant_id', 'accountant', 'Accounts');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 2);
select id as bed1 from public.hostel_bed where bed_code = 'IQ-101-B1' \gset
select public.create_student(:'campus_id'::uuid, 'Resident', '2012-01-01'::date, 'male') as sa \gset
select public.create_student(:'campus_id'::uuid, 'Day Scholar', '2012-01-01'::date, 'male') as sb \gset
select public.enrol_student(:'section_id'::uuid, :'sa'::uuid);
select public.enrol_student(:'section_id'::uuid, :'sb'::uuid);
select public.allocate_bed(:'sa'::uuid, :'bed1'::uuid, current_date - 5);

select is(public.mark_hostel_roll_call(:'campus_id'::uuid, current_date, 'night', jsonb_build_array(jsonb_build_object('student_id', :'sa', 'status', 'present'))), 1, 'the warden marks a resident present at night');
select is(public.mark_hostel_roll_call(:'campus_id'::uuid, current_date, 'night', jsonb_build_array(jsonb_build_object('student_id', :'sa', 'status', 'absent'))), 1, 'marking again corrects it');
select is((select status from public.hostel_roll_call where student_id = :'sa'), 'absent', 'one row per student, date and session');
select throws_ok(format($$ select public.mark_hostel_roll_call(%L, current_date, 'night', '[{"student_id": "%s", "status": "present"}]') $$, :'campus_id', :'sb'), 'P0002', 'NOT_A_RESIDENT', 'a day scholar is not on the roll call');

select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.mark_hostel_roll_call(%L, current_date, 'night', '[]') $$, :'campus_id'), '42501', 'FORBIDDEN', 'an accountant cannot mark roll call');

select * from finish();
rollback;
