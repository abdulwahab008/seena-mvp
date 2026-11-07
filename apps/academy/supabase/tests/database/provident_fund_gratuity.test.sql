begin;
select plan(7);

select public.provision_tenant('test-pf-gratuity', 'PF Gratuity Co', 'owner@pfgratuity.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name, doj)
values (:'tenant_id', :'campus_id', 'E-1', '35201-3333333-3', 'male', 'Sir Kamran', current_date - interval '7 years 2 months') returning id as staff_id \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name, doj)
values (:'tenant_id', :'campus_id', 'E-2', '35201-4444444-4', 'female', 'Ms New', current_date - 100) returning id as new_id \gset
insert into public.employee_salary_structure (tenant_id, campus_id, staff_id, validity, basic_paisa)
values (:'tenant_id', :'campus_id', :'staff_id', daterange(current_date - 30, null), 6000000);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.add_provident_fund_components(25, 5) $$, '22023', 'PCT_INVALID', 'shares are capped at 20%');
select is(public.add_provident_fund_components(5, 5), 2, 'employee and school shares are added');
select throws_ok($$ select public.add_provident_fund_components(5, 5) $$, '22023', 'PF_EXISTS', 'only once');
reset role;
select is((select string_agg(code || ':' || component_type || ':' || calc_pct::numeric(5,2), ',' order by code) from public.salary_component where tenant_id = :'tenant_id' and code like 'PF_%'),
  'PF_EE:deduction:5.00,PF_ER:employer_contribution:5.00', 'as a deduction and an employer contribution on basic');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select is((select years_completed || ' ' || gratuity_paisa from public.gratuity_liability() where staff_id = :'staff_id'), '7 42000000',
  'gratuity is one month''s basic per completed year');
select is((select gratuity_paisa from public.gratuity_liability() where staff_id = :'new_id'), 0::bigint, 'nothing before a full year');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select * from public.gratuity_liability() $$, '42501', 'FORBIDDEN', 'payroll figures are for payroll roles');

select * from finish();
rollback;
