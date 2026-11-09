begin;
select plan(8);

select public.provision_tenant('test-reports-to', 'Reports To Co', 'owner@reportsto.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-reports-to-2', 'Other School', 'owner@reportsto2.test') as other_tenant \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', 'RT-1', '42101-4444444-1', 'female', 'Principal Head'),
  (:'tenant_id', :'campus_id', 'RT-2', '42101-4444444-2', 'male', 'Coordinator'),
  (:'tenant_id', :'campus_id', 'RT-3', '42101-4444444-3', 'female', 'Teacher');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name) values
  (:'other_tenant', :'other_campus', 'RT-9', '42101-4444444-9', 'male', 'Elsewhere');
select id as head from public.staff where employee_code = 'RT-1' and tenant_id = :'tenant_id' \gset
select id as coord from public.staff where employee_code = 'RT-2' and tenant_id = :'tenant_id' \gset
select id as teach from public.staff where employee_code = 'RT-3' and tenant_id = :'tenant_id' \gset
select id as outsider from public.staff where employee_code = 'RT-9' and tenant_id = :'other_tenant' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'coord', :'head'), 'HR puts the coordinator under the head');
select lives_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'teach', :'coord'), 'and the teacher under the coordinator');
select throws_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'head', :'teach'), '22023', 'REPORTING_CYCLE', 'the head cannot report to someone below them');
select throws_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'head', :'head'), '22023', 'REPORTING_CYCLE', 'or to themselves');
select throws_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'teach', :'outsider'), 'P0002', 'MANAGER_NOT_FOUND', 'a manager from another school is refused');
select lives_ok(format($$ select public.set_staff_manager(%L, null) $$, :'teach'), 'clearing the manager is allowed');
reset role;
select is((select reports_to_staff_id from public.staff where id = :'coord'), :'head'::uuid, 'the link is stored');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_staff_manager(%L, %L) $$, :'teach', :'head'), '42501', 'FORBIDDEN', 'a teacher cannot change the chart');

select * from finish();
rollback;
