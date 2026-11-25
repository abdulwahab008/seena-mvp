begin;
select plan(9);

select public.provision_tenant('test-paylock-co', 'Paylock Co', 'owner@paylock.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'uid', 'own@paylock.test', 'authenticated', 'authenticated', 'x');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
values (:'tenant_id', :'campus_id', 'E-1', '35201-1234567-1', 'female', 'Teacher One') returning id as staff_id \gset
insert into public.payroll_run (tenant_id, campus_id, period_month) values (:'tenant_id', :'campus_id', '2026-09-01') returning id as run_id \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_id'))::text, true);

-- Payroll: draft → submitted → approved → locked, no shortcut.
select throws_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_id'), '55000', 'RUN_NOT_APPROVED', 'a draft run cannot be locked');
select public.fn_submit_payroll_for_approval(:'run_id'::uuid);
select throws_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_id'), '55000', 'RUN_NOT_APPROVED', 'nor a submitted run nobody has approved');
select public.fn_approve_payroll_run(:'run_id'::uuid);
select lives_ok(format($$ select public.fn_lock_payroll_run(%L) $$, :'run_id'), 'an approved run locks');
select is((select status from public.payroll_run where id = :'run_id'), 'locked', 'and is locked');

-- Bank account: validated, normalised, replaced in place.
select throws_ok(format($$ select public.set_staff_bank_account(%L, 'HBL', 'Teacher One', '12-34') $$, :'staff_id'), '22023', 'ACCOUNT_NO_INVALID', 'a short account number is refused');
select public.set_staff_bank_account(:'staff_id'::uuid, 'Meezan Bank', 'Teacher One', 'pk36 meza 0000 0012 3456 7890');
select is((select account_no from public.staff_bank_account where staff_id = :'staff_id'), 'PK36MEZA0000001234567890', 'an IBAN is stored without spaces, upper-cased');
select public.set_staff_bank_account(:'staff_id'::uuid, 'HBL', 'Teacher One', '0123-4567-8901');
select is((select bank_name || ' ' || account_no from public.staff_bank_account where staff_id = :'staff_id'), 'HBL 012345678901', 'saving again replaces the account');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
  'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_staff_bank_account(%L, 'HBL', 'X', '1234567') $$, :'staff_id'), '42501', 'FORBIDDEN', 'a teacher cannot set anyone''s bank account');
select is((select count(*)::int from public.staff_bank_account), 0, 'nor read another staff member''s');

select * from finish();
rollback;
