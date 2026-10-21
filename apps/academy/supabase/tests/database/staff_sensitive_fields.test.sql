-- pgTAP tests: staff identity numbers, birth dates and bank details are not open to every colleague.
--
-- The staff register is readable by anyone whose token carries the campus, so a class teacher could
-- ask the API for every colleague's CNIC, passport number and date of birth, and the employee bank
-- detail table let in any role with the campus. The identity columns are now closed to the API and
-- read through staff_identity(), for the person themselves, super admin / owner, and principal /
-- HR manager of the same campus.
begin;
select plan(27);

select public.provision_tenant('test-staff-sens-a', 'Staff Sensitive A', 'owner@staffsens-a.test');
select public.provision_tenant('test-staff-sens-b', 'Staff Sensitive B', 'owner@staffsens-b.test');
select id as tenant_a from public.tenant where slug = 'test-staff-sens-a' \gset
select id as tenant_b from public.tenant where slug = 'test-staff-sens-b' \gset
select id as khi from public.campus where tenant_id = :'tenant_a' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_a', 'LHR', 'Lahore Campus') returning id as lhr \gset
select id as campus_b from public.campus where tenant_id = :'tenant_b' \gset

-- people: every auth user and app_user row is created up front, as the database owner
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as accountant_uid \gset
select gen_random_uuid() as librarian_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as principal_uid \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as owner_b_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'teacher_uid', 'teacher@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'accountant_uid', 'accountant@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'librarian_uid', 'librarian@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'hr_uid', 'hr@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'principal_uid', 'principal@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'owner_uid', 'owner@staffsens.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'owner_b_uid', 'owner-b@staffsens.test', 'x', now(), 'authenticated', 'authenticated');

-- the register: the teacher's own row, a colleague at the same campus, one at the other campus, one at school B
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, dob, gender, full_name) values
  (:'tenant_a', :'khi', :'teacher_uid', 'SS-001', '42101-1111111-1', '1990-01-01', 'female', 'Own Row Teacher');
select id as staff_own from public.staff where employee_code = 'SS-001' and tenant_id = :'tenant_a' \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, dob, gender, full_name)
values (:'tenant_a', :'khi', 'SS-002', '42101-2222222-2', '1985-02-02', 'male', 'Colleague Khi') returning id as staff_khi \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, dob, gender, full_name)
values (:'tenant_a', :'lhr', 'SS-003', '35202-3333333-3', '1980-03-03', 'male', 'Colleague Lhr') returning id as staff_lhr \gset
insert into public.staff (tenant_id, campus_id, employee_code, cnic, dob, gender, full_name)
values (:'tenant_b', :'campus_b', 'SS-004', '61101-4444444-4', '1975-04-04', 'female', 'School B Staff') returning id as staff_b \gset

insert into public.employee_bank_detail (tenant_id, campus_id, staff_id, bank_name, account_title, account_number) values
  (:'tenant_a', :'khi', :'staff_own', 'Habib Bank', 'Own Row Teacher', '0001'),
  (:'tenant_a', :'khi', :'staff_khi', 'Meezan Bank', 'Colleague Khi', '0002');

-- ── what the API can read ──────────────────────────────────────────────────────
select is(
  (select array_agg(a.attname::text order by a.attname)
     from pg_attribute a
    where a.attrelid = 'public.staff'::regclass and a.attnum > 0 and not a.attisdropped
      and not has_column_privilege('authenticated', 'public.staff', a.attname, 'select')),
  array['cnic', 'dob', 'passport_no'],
  'the only staff columns signed-in users cannot read are the identity number, passport number and date of birth'
);
select ok(
  not has_table_privilege('anon', 'public.staff', 'select') and not has_any_column_privilege('anon', 'public.staff', 'select'),
  'and a signed-out caller cannot read the staff register at all'
);

-- ── a class teacher at the campus ────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'teacher_uid', 'tenant_id', :'tenant_a',
  'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'khi'))::text, true);

select lives_ok($$ select id, employee_code, full_name, full_name_ur, designation_id, department_id, employment_status, gender, doj, contract_type, user_id, campus_id from public.staff $$,
  'a teacher can still read the directory columns of the register');
select is((select count(*)::int from public.staff), 2, 'and sees the two staff of their own campus');
select throws_ok($$ select cnic from public.staff $$, '42501', null, 'but not their colleagues'' CNIC numbers');
select throws_ok($$ select dob from public.staff $$, '42501', null, 'nor their dates of birth');
select throws_ok($$ select passport_no from public.staff $$, '42501', null, 'nor their passport numbers');
select throws_ok($$ select * from public.staff $$, '42501', null, 'and select * on the register is refused rather than quietly returning them');
select is((select cnic from public.staff_identity(:'staff_own')), '42101-1111111-1', 'they read their own identity through staff_identity');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_khi'), 'FORBIDDEN', 'but not a colleague''s');
select is((select count(*)::int from public.employee_bank_detail), 1, 'and see only their own bank details, not the colleague''s');

-- ── other roles at the campus ─────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'librarian_uid', 'tenant_id', :'tenant_a',
  'app_role', 'librarian', 'campus_ids', json_build_array(:'khi'))::text, true);
select is((select count(*)::int from public.employee_bank_detail), 0, 'a librarian sees no bank details');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_khi'), 'FORBIDDEN', 'and no colleague''s identity');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'accountant_uid', 'tenant_id', :'tenant_a',
  'app_role', 'accountant', 'campus_ids', json_build_array(:'khi'))::text, true);
select is((select count(*)::int from public.employee_bank_detail), 2, 'an accountant (payroll) still sees the bank details');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_khi'), 'FORBIDDEN', 'but not identity numbers, which payroll does not need');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'hr_uid', 'tenant_id', :'tenant_a',
  'app_role', 'hr_manager', 'campus_ids', json_build_array(:'khi'))::text, true);
select is((select cnic from public.staff_identity(:'staff_khi')), '42101-2222222-2', 'an HR manager reads a colleague''s identity at their campus');
select is((select dob from public.staff_identity(:'staff_khi')), '1985-02-02'::date, 'including the date of birth');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_lhr'), 'FORBIDDEN', 'but not at a campus they are not assigned to');
select is((select count(*)::int from public.employee_bank_detail), 2, 'and sees the bank details');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'principal_uid', 'tenant_id', :'tenant_a',
  'app_role', 'principal', 'campus_ids', json_build_array(:'khi'))::text, true);
select is((select cnic from public.staff_identity(:'staff_khi')), '42101-2222222-2', 'a principal reads identity at their campus');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_lhr'), 'FORBIDDEN', 'and not at another campus');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_a',
  'app_role', 'owner', 'campus_ids', json_build_array(:'khi'))::text, true);
select is((select cnic from public.staff_identity(:'staff_lhr')), '35202-3333333-3', 'the owner reads identity at any campus of the school');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_b'), 'P0002', null, 'but another school''s staff do not exist for them');
select throws_ok(format($$ select * from public.staff_identity(%L) $$, gen_random_uuid()), 'P0002', null, 'and neither does an id that is not in the register');

select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', gen_random_uuid(), 'tenant_id', :'tenant_a',
  'app_role', 'parent', 'campus_ids', json_build_array(:'khi'))::text, true);
select throws_ok(format($$ select * from public.staff_identity(%L) $$, :'staff_khi'), 'FORBIDDEN', 'a parent cannot read staff identity');
reset role;

-- ── the server side is unchanged ─────────────────────────────────────────────
select is((select cnic from public.staff where id = :'staff_khi'), '42101-2222222-2', 'the database owner still reads the register in full');
set local role service_role;
select is((select dob from public.staff where id = :'staff_khi'), '1985-02-02'::date, 'and so does the service role');
reset role;

select * from finish();
rollback;
