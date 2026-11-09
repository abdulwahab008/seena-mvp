begin;
select plan(9);

select public.provision_tenant('test-pay-scales', 'Pay Scales Co', 'owner@payscales.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-pay-scales-2', 'Other School', 'owner@payscales2.test') as other_tenant \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
values (:'tenant_id', :'campus_id', 'PS-1', '42101-5555555-1', 'female', 'Scaled Teacher') returning id as staff_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_pay_scale(null, 'bps-14', 'Basic Pay Scale 14', 3500000, 6500000, 150000) as scale_id \gset
select is((select code from public.pay_scale where id = :'scale_id'), 'BPS-14', 'HR adds a pay scale; the code is upper-cased');
select throws_ok($$ select public.save_pay_scale(null, 'BPS-15', 'Inverted', 5000000, 4000000, 0) $$, '22023', 'BAND_INVALID', 'the maximum cannot be below the minimum');
select throws_ok($$ select public.save_pay_scale(null, 'BPS-14', 'Duplicate', 1, 2, 0) $$, '23505', null, 'codes are unique per school');
select lives_ok(format($$ select public.save_pay_scale(%L, 'BPS-14', 'Basic Pay Scale 14', 3500000, 7000000, 150000) $$, :'scale_id'), 'HR edits the band');

insert into public.employee_salary_structure (tenant_id, campus_id, staff_id, validity, basic_paisa, pay_scale_id)
values (:'tenant_id', :'campus_id', :'staff_id', daterange('2026-01-01', '2026-06-30', '[]'), 4000000, :'scale_id');
select is((select count(*)::int from public.employee_salary_structure where pay_scale_id = :'scale_id'), 1, 'a salary structure can sit on the scale');
select throws_ok(
  format($$ insert into public.employee_salary_structure (tenant_id, campus_id, staff_id, validity, basic_paisa, pay_scale_id)
            values (%L, %L, %L, daterange('2026-07-01', null, '[)'), 9000000, %L) $$, :'tenant_id', :'campus_id', :'staff_id', :'scale_id'),
  '22023', 'BASIC_OUTSIDE_PAY_SCALE', 'a basic outside the band is refused');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.save_pay_scale(null, 'BPS-1', 'X', 1, 2, 0) $$, '42501', 'FORBIDDEN', 'a teacher cannot add pay scales');
select is((select count(*)::int from public.pay_scale), 0, 'or read them');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.pay_scale), 0, 'another school sees none of them');

select * from finish();
rollback;
