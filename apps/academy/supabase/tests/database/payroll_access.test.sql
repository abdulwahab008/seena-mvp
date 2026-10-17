-- pgTAP tests: payroll is for the people who run payroll.
--
-- generate_payroll_run() checked nobody, and the submit/approve/lock functions had a role check that
-- could never fire (current_user is always the owner inside a SECURITY DEFINER function), so any
-- signed-in user could generate, approve or lock any school's payroll. The payroll read policies also
-- let in everyone whose token carries the campus: every teacher, nurse, parent and student.
begin;
select plan(35);

select public.provision_tenant('test-payroll-access-a', 'Payroll Access A', 'owner@payrollaccess-a.test');
select public.provision_tenant('test-payroll-access-b', 'Payroll Access B', 'owner@payrollaccess-b.test');
select id as tenant_a from public.tenant where slug = 'test-payroll-access-a' \gset
select id as tenant_b from public.tenant where slug = 'test-payroll-access-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset

select gen_random_uuid() as emp_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password)
values (:'emp_uid', 'employee@payrollaccess.test', 'authenticated', 'authenticated', 'x');

insert into public.staff (tenant_id, campus_id, user_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_a', :'campus_a', :'emp_uid', 'EMP-A1', 'Employee One', 'male', 'cnic', '35201-1111111-1', '2026-01-01', 'active')
returning id as staff1 \gset
insert into public.staff (tenant_id, campus_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_a', :'campus_a', 'EMP-A2', 'Employee Two', 'female', 'cnic', '35201-2222222-2', '2026-01-01', 'active')
returning id as staff2 \gset
insert into public.staff (tenant_id, campus_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_b', :'campus_b', 'EMP-B1', 'Employee Three', 'male', 'cnic', '35201-3333333-3', '2026-01-01', 'active')
returning id as staff3 \gset
insert into public.employee_salary_structure (tenant_id, campus_id, staff_id, validity, basic_paisa) values
  (:'tenant_a', :'campus_a', :'staff1', daterange('2026-01-01', '2026-12-31', '[]'), 8000000),
  (:'tenant_a', :'campus_a', :'staff2', daterange('2026-01-01', '2026-12-31', '[]'), 6000000),
  (:'tenant_b', :'campus_b', :'staff3', daterange('2026-01-01', '2026-12-31', '[]'), 7000000);
insert into public.staff_loan (tenant_id, campus_id, staff_id, loan_type, principal_paisa, installment_paisa, disbursed_at, repayment_start_month, status)
values (:'tenant_a', :'campus_a', :'staff1', 'loan', 10000000, 1000000, '2026-08-01', '2026-08-01', 'active');

-- the server side builds one run per school
select set_config('request.jwt.claims', '', true);
select public.generate_payroll_run(:'campus_a'::uuid, '2026-08-01'::date) as run_a \gset
select public.generate_payroll_run(:'campus_b'::uuid, '2026-08-01'::date) as run_b \gset
select is((select count(*)::int from public.payroll_run_line where payroll_run_id = :'run_a'), 2, 'fixture: school A''s run has a line for each of its two staff');
insert into public.payroll_run_line_component (line_id, component_id, code, name_en, component_type, amount_paisa, is_taxable)
select l.id, (select c.id from public.salary_component c where c.tenant_id = :'tenant_a' order by c.code limit 1), 'BASIC', 'Basic', 'earning', l.basic_paisa, true
  from public.payroll_run_line l where l.payroll_run_id = :'run_a';

-- ── a class teacher at school A ──────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.generate_payroll_run(%L, '2026-08-01') $$, :'campus_a'), 'FORBIDDEN', 'a teacher cannot generate payroll');
select throws_ok(format($$ select public.fn_submit_payroll_for_approval(%L) $$, :'run_a'), 'FORBIDDEN', 'nor submit a run for approval');
select throws_ok(format($$ select public.fn_approve_payroll_run(%L) $$, :'run_a'), 'FORBIDDEN', 'nor approve one');
select throws_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_a'), 'FORBIDDEN', 'nor lock one');
select is((select count(*)::int from public.payroll_run), 0, 'a teacher sees no payroll runs');
select is((select count(*)::int from public.payroll_run_line), 0, 'no payroll lines');
select is((select count(*)::int from public.payroll_run_line_component), 0, 'no pay components');
select is((select count(*)::int from public.employee_salary_structure), 0, 'no salary structures');
select is((select count(*)::int from public.staff_loan), 0, 'and no staff loans');
reset role;

-- ── a parent and a student at school A: their tokens carry the campus too ──────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_a', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.payroll_run_line) + (select count(*)::int from public.employee_salary_structure) + (select count(*)::int from public.staff_loan), 0,
  'a parent sees no payroll, salary or loan rows');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_a', 'app_role', 'student',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.payroll_run) + (select count(*)::int from public.salary_component), 0, 'a student sees no payroll runs or pay components');
reset role;

-- ── an employee reads only their own pay ─────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'emp_uid', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select array_agg(staff_id::text) from public.payroll_run_line), array[:'staff1']::text[], 'an employee sees their own payroll line and nobody else''s');
select is((select count(*)::int from public.employee_salary_structure), 1, 'their own salary structure');
select is((select count(*)::int from public.staff_loan), 1, 'and their own loan');
select is((select count(*)::int from public.payroll_run_line_component), 1, 'and the pay components of their own line only');
select ok((select count(*) from public.salary_component) > 0, 'staff can still see the school''s pay component catalogue');
reset role;

-- ── an accountant at school B cannot touch school A ──────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_b', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select public.generate_payroll_run(%L, '2026-08-01') $$, :'campus_a'), 'FORBIDDEN', 'another school''s accountant cannot generate payroll for this campus');
select throws_ok(format($$ select public.fn_submit_payroll_for_approval(%L) $$, :'run_a'), 'FORBIDDEN', 'nor submit its run');
select is((select count(*)::int from public.payroll_run where id = :'run_a'), 0, 'nor see it');
select is((select count(*)::int from public.payroll_run), 1, 'they see their own school''s run');
reset role;

-- ── an accountant at school A ────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'accountant',
  'campus_ids', '[]'::json)::text, true);
select throws_ok(format($$ select public.generate_payroll_run(%L, '2026-08-01') $$, :'campus_a'), 'FORBIDDEN', 'an accountant with no campus assigned cannot generate payroll');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select lives_ok(format($$ select public.generate_payroll_run(%L, '2026-09-01') $$, :'campus_a'), 'an accountant at the campus can generate payroll');
select is((select count(*)::int from public.payroll_run_line where payroll_run_id = :'run_a'), 2, 'they read the August run''s lines');
select is((select count(*)::int from public.payroll_run_line_component), 2, 'and their components');
reset role;
select id as run_a2 from public.payroll_run where campus_id = :'campus_a' and period_month = '2026-09-01' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select lives_ok(format($$ select public.fn_submit_payroll_for_approval(%L) $$, :'run_a2'), 'and submit it for approval');
select throws_ok(format($$ select public.fn_approve_payroll_run(%L) $$, :'run_a2'), 'FORBIDDEN', 'but approval is for the owner');
reset role;

-- ── an HR manager at school A ────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'hr_manager',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.employee_salary_structure), 2, 'an HR manager reads the campus''s salary structures');
select is((select count(*)::int from public.staff_loan), 1, 'and its loans');
reset role;

-- ── owners: school B''s owner is turned away, school A''s approves and locks ────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_b', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select public.fn_approve_payroll_run(%L) $$, :'run_a2'), 'FORBIDDEN', 'another school''s owner cannot approve this run');
select throws_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_a2'), 'FORBIDDEN', 'nor lock it');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select lives_ok(format($$ select public.fn_approve_payroll_run(%L) $$, :'run_a2'), 'the school''s own owner can approve it');
select lives_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_a2'), 'and lock it');
reset role;

-- ── the helpers behind a pay run are not callable by signed-in users ──────────
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname = any (array['fn_accrue_loan_recovery', 'fn_active_salary_structure', 'fn_attendance_deduction_paisa',
                                 'fn_salary_for_period', 'fn_unpaid_days', 'seed_default_salary_components'])
      and has_function_privilege('authenticated', p.oid, 'execute')),
  null,
  'the helpers that return one person''s pay are service role only'
);
select ok(
  has_function_privilege('service_role', 'public.fn_active_salary_structure(uuid, date)'::regprocedure, 'execute'),
  'and the service role keeps them'
);

select * from finish();
rollback;
