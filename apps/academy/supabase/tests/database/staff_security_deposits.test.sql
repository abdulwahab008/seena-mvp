begin;
select plan(9);

select public.provision_tenant('test-deposit-co', 'Deposit Co', 'owner@deposit.test');
select id as tenant_id from public.tenant where slug = 'test-deposit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as acc_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'h@deposit.test', 'authenticated', 'authenticated', 'x'), (:'acc_uid', 'a@deposit.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@deposit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'acc_uid', :'tenant_id', 'accountant', 'Accountant'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, doj, full_name)
values (:'tenant_id', :'campus_id', 'DP-1', '42101-4444444-1', 'male', '2020-01-01', 'Deposit Holder');
select id as s1 from public.staff where employee_code = 'DP-1' and tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_staff_security_deposit(%L, 3000000, 500000, '2026-06-01') $$, :'s1'), '42501', 'FORBIDDEN', 'a teacher cannot start a security deposit');

select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_staff_security_deposit(%L, 300000, 500000, '2026-06-01') $$, :'s1'), '22023', 'AMOUNT_INVALID', 'the instalment cannot exceed the target');
select public.create_staff_security_deposit(:'s1'::uuid, 3000000, 500000, '2026-06-15') as dep \gset
select is((select repayment_start_month::text || '|' || loan_type from public.staff_loan where id = :'dep'), '2026-06-01|security_deposit', 'the deposit starts at the beginning of the month');
select throws_ok(format($$ select public.create_staff_security_deposit(%L, 3000000, 500000, '2026-07-01') $$, :'s1'), '23505', 'DEPOSIT_EXISTS', 'one open deposit per staff member');

select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_staff_contract(:'s1'::uuid, 'permanent', '2026-01-01'::date, null, 30::smallint, 50000);
select public.initiate_staff_exit(:'s1'::uuid, 'retirement', null, '2026-09-30'::date) as ex1 \gset
reset role;
update public.staff_loan set total_repaid_paisa = 1500000 where id = :'dep';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_settlement_draft(:'ex1'::uuid) as st1 \gset
select is((select amount_paisa from public.staff_settlement_line where settlement_id = :'st1'::uuid and description = 'Security deposit refund' and sign = 1), 1500000::bigint, 'the Rs 15,000 collected is refunded at exit');
select is((select count(*) from public.staff_settlement_line where settlement_id = :'st1'::uuid and line_type = 'advance_recovery'), 0::bigint, 'the uncollected part of the deposit is not recovered from the staff member');
select is((select net_payable_paisa from public.staff_settlement where id = :'st1'::uuid), 6500000::bigint, 'a full month of Rs 50,000 plus the Rs 15,000 deposit');
select public.approve_settlement(:'st1'::uuid);
select public.mark_settlement_paid(:'st1'::uuid);
reset role;
select ok((select refunded_at is not null and status = 'closed' from public.staff_loan where id = :'dep'), 'paying the settlement marks the deposit refunded');
select is((select total_repaid_paisa from public.staff_loan where id = :'dep'), 1500000::bigint, 'the amount collected is left as it was');

select * from finish();
rollback;
