begin;
select plan(7);

select public.provision_tenant('test-office-tools', 'Office Tools Co', 'owner@officetools.test') as tenant_id \gset
select gen_random_uuid() as rec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as other_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'rec_uid', 'r@officetools.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@officetools.test', 'authenticated', 'authenticated', 'x'),
  (:'other_uid', 'x@officetools.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'rec_uid', :'tenant_id', 'receptionist', 'Reception'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'other_uid', :'tenant_id', 'librarian', 'Librarian');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'rec_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist')::text, true);
select isnt(public.save_office_contact('Dr Asif', 'City Clinic', 'medical', '0421234567', null), null, 'reception adds a contact');
select public.add_team_task('Order chalk for Class 5', :'teach_uid', current_date + 2) as task_id \gset

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select is((select count(*)::int from public.office_contact), 1, 'staff can read the directory');
select throws_ok($$ select public.save_office_contact('X', null, 'other', null, null) $$, '42501', 'FORBIDDEN', 'but a teacher cannot add to it');
select set_config('request.jwt.claims', json_build_object('sub', :'other_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian')::text, true);
select throws_ok(format($$ select public.complete_team_task(%L) $$, :'task_id'), '42501', 'FORBIDDEN', 'someone else cannot tick off the task');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select public.complete_team_task(:'task_id');
select isnt((select done_at from public.team_task where id = :'task_id'), null, 'the person it is assigned to ticks it off');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.office_contact) + (select count(*)::int from public.team_task), 0, 'parents see neither');
select throws_ok($$ select public.add_team_task('x') $$, '42501', 'FORBIDDEN', 'or add tasks');

select * from finish();
rollback;
