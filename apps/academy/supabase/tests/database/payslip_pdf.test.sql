-- pgTAP tests for FR-L08: payslips for a locked payroll run.
begin;
select plan(21);

select public.provision_tenant('test-payslip-a', 'Payslip A', 'owner@payslip-a.test');
select public.provision_tenant('test-payslip-b', 'Payslip B', 'owner@payslip-b.test');
select id as tenant_a from public.tenant where slug = 'test-payslip-a' \gset
select id as tenant_b from public.tenant where slug = 'test-payslip-b' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_a' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset

select gen_random_uuid() as emp_uid \gset
select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'emp_uid', 'employee@payslip.test', 'authenticated', 'authenticated', 'x'),
  (:'owner_uid', 'o@payslip.test', 'authenticated', 'authenticated', 'x');

insert into public.staff (tenant_id, campus_id, user_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_a', :'campus_a', :'emp_uid', 'EMP-A1', 'Employee One', 'male', 'cnic', '35201-1111111-1', '2026-01-01', 'active')
returning id as staff1 \gset
insert into public.staff (tenant_id, campus_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_a', :'campus_a', 'EMP-A2', 'Employee Two', 'female', 'cnic', '35201-2222222-2', '2026-01-01', 'active')
returning id as staff2 \gset
insert into public.employee_salary_structure (tenant_id, campus_id, staff_id, validity, basic_paisa) values
  (:'tenant_a', :'campus_a', :'staff1', daterange('2026-01-01', '2026-12-31', '[]'), 8000000),
  (:'tenant_a', :'campus_a', :'staff2', daterange('2026-01-01', '2026-12-31', '[]'), 6000000);
insert into public.staff_loan (tenant_id, campus_id, staff_id, loan_type, principal_paisa, installment_paisa, disbursed_at, repayment_start_month, status)
values (:'tenant_a', :'campus_a', :'staff1', 'loan', 10000000, 1000000, '2026-08-01', '2026-08-01', 'active');

select set_config('request.jwt.claims', '', true);
select public.generate_payroll_run(:'campus_a'::uuid, '2026-08-01'::date) as run_a \gset
insert into public.payroll_run_line_component (line_id, component_id, code, name_en, component_type, amount_paisa, is_taxable)
select l.id, (select c.id from public.salary_component c where c.tenant_id = :'tenant_a' order by c.code limit 1), 'BASIC', 'Basic', 'earning', l.basic_paisa, true
  from public.payroll_run_line l where l.payroll_run_id = :'run_a';
select id as line1 from public.payroll_run_line where payroll_run_id = :'run_a' and staff_id = :'staff1' \gset
select id as line2 from public.payroll_run_line where payroll_run_id = :'run_a' and staff_id = :'staff2' \gset

-- ── a draft run has no payslips ──────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select * from public.payslip_run_lines(%L) $$, :'run_a'), '55000', 'run_not_locked', 'AC: a run still in draft has no payslips to generate');
select throws_ok(format($$ select public.payslip_payload(%L) $$, :'line1'), '55000', 'run_not_locked', 'nor can one line of it be rendered');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select public.fn_lock_payroll_run(:'run_a'::uuid);
reset role;

-- ── a locked run gives the full itemised payload ─────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.payslip_run_lines(:'run_a'::uuid)), 2, 'a locked run lists a line for each of its two employees');
select public.payslip_payload(:'line1'::uuid) as payload1 \gset
select is(jsonb_array_length(:'payload1'::jsonb -> 'earnings'), 1, 'the payslip itemises earnings');
select is(:'payload1'::jsonb ->> 'net_in_words', public.amount_in_words((:'payload1'::jsonb ->> 'net_paisa')::bigint), 'net pay is printed in words as well as figures');
select is((:'payload1'::jsonb ->> 'loan_outstanding_paisa')::bigint, 9000000::bigint, 'the outstanding loan balance is shown, after this run''s installment');

-- ── another school cannot reach this run ─────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_b', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select * from public.payslip_run_lines(%L) $$, :'run_a'), 'P0002', 'RUN_NOT_FOUND', 'another school''s owner cannot list this run''s payslips');

-- ── an employee reads their own payslip and not a colleague's ────────────────
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'emp_uid', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select lives_ok(format($$ select public.payslip_payload(%L) $$, :'line1'), 'an employee can render their own payslip');
select throws_ok(format($$ select public.payslip_payload(%L) $$, :'line2'), '42501', 'FORBIDDEN', 'AC: employee A cannot read employee B''s payslip');
reset role;

-- ── the ledger: versions are added, never overwritten ────────────────────────
select ok(public.register_payslip(:'line1'::uuid, 1, :'tenant_a' || '/' || :'run_a' || '/' || :'staff1' || '-v1.pdf', repeat('a', 64), null) is not null, 'the first payslip version is recorded');
select ok(public.register_payslip(:'line1'::uuid, 2, :'tenant_a' || '/' || :'run_a' || '/' || :'staff1' || '-v2.pdf', repeat('b', 64), null) is not null, 'AC: a regeneration adds version 2');
select public.register_payslip(:'line2'::uuid, 1, :'tenant_a' || '/' || :'run_a' || '/' || :'staff2' || '-v1.pdf', repeat('c', 64), null);
select throws_ok(
  format($$ select public.register_payslip(%L, 2, 'x', %L, null) $$, :'line1', repeat('d', 64)),
  '23505',
  null,
  'a version number cannot be written twice, so an earlier file is never replaced'
);
set local role authenticated;
select throws_ok(
  format($$ select public.register_payslip(%L, 3, 'x', %L, null) $$, :'line1', repeat('e', 64)),
  '42501',
  null,
  'only the server writes to the payslip ledger'
);

-- ── reads, and the audit of a refused request ────────────────────────────────
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'emp_uid', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.payslip), 2, 'an employee sees only their own two payslip versions');
select lives_ok(format($$ select public.record_payslip_denied(%L) $$, gen_random_uuid()), 'a refused request is recorded');
reset role;
select is((select count(*)::int from public.payslip_denied_access where tenant_id = :'tenant_a'), 1, 'the attempt is on file');
select is((select count(*)::int from public.audit_log where table_name = 'payslip_denied_access' and tenant_id = :'tenant_a'), 1, 'AC: and it reached audit_log');

-- ── the private bucket follows the same rule, file by file ───────────────────
insert into storage.objects (bucket_id, name) values
  ('payslips', :'tenant_a' || '/' || :'run_a' || '/' || :'staff1' || '-v1.pdf'),
  ('payslips', :'tenant_a' || '/' || :'run_a' || '/' || :'staff2' || '-v1.pdf');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_a', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from storage.objects where bucket_id = 'payslips'), 2, 'the school''s owner can open every payslip file');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'emp_uid', 'tenant_id', :'tenant_a', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from storage.objects where bucket_id = 'payslips'), 1, 'an employee can open only their own file');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_a', 'app_role', 'class_teacher',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from storage.objects where bucket_id = 'payslips'), 0, 'a colleague with no payroll role and no payslip of their own sees none');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_b', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from storage.objects where bucket_id = 'payslips'), 0, 'another school''s owner sees none');

select * from finish();
rollback;
