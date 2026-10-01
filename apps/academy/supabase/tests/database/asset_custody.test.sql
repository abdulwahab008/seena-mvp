-- pgTAP tests for FR-R04: asset issue to department / room / staff custody.
begin;
select plan(23);

select public.provision_tenant('test-custody-co', 'Custody Co', 'owner@custody.test');
select id as tenant_id from public.tenant where slug = 'test-custody-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-custody-other', 'Other Custody Co', 'owner@othercustody.test');
select id as other_tenant_id from public.tenant where slug = 'test-custody-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as hod_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@custody.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@custody.test', 'authenticated', 'authenticated', 'x'),
  (:'hr_uid', 'h@custody.test', 'authenticated', 'authenticated', 'x'), (:'hod_uid', 'hod@custody.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@custody.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'),
  (:'hod_uid', :'tenant_id', 'head_of_department', 'Chem HOD'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Other Teacher');
insert into public.department (tenant_id, code, name_en) values (:'tenant_id', 'CHEM', 'Chemistry') returning id as dept_chem \gset
insert into public.department (tenant_id, code, name_en) values (:'tenant_id', 'PHY', 'Physics') returning id as dept_phy \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_staff(:'campus_id'::uuid, 'Chem HOD', 'male', p_cnic => '42101-1234568-1') as hod_staff \gset
select public.create_staff(:'campus_id'::uuid, 'Leaving Teacher', 'female', p_cnic => '42101-1234568-2') as leaver \gset
reset role;
update public.staff set user_id = :'hod_uid' where id = :'hod_staff';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_asset(:'campus_id'::uuid, 'IT-0042', 'Laptop', 'it', '2026-01-01'::date, 15000000, 36) as laptop \gset
select public.create_asset(:'campus_id'::uuid, 'IT-0043', 'Tablet', 'it', '2026-01-01'::date, 5000000, 36) as tablet \gset
select public.create_asset(:'campus_id'::uuid, 'IT-0044', 'Camera', 'it', '2026-01-01'::date, 5000000, 36) as camera \gset
select public.create_asset(:'campus_id'::uuid, 'IT-0045', 'Printer', 'it', '2026-01-01'::date, 5000000, 36) as printer \gset

-- ── AC1: custody is a history, queryable as at a date ─────────────────────
select public.issue_asset_custody(:'laptop'::uuid, 'department', :'dept_chem'::uuid, null, null, '2026-03-01'::date) as c1 \gset
select public.return_asset_custody(:'c1'::uuid, 'good', '2026-07-10'::date);
select public.issue_asset_custody(:'laptop'::uuid, 'department', :'dept_phy'::uuid, null, null, '2026-07-10'::date) as c2 \gset
select is((select custodian_name from public.v_asset_custody_asof('2026-05-01'::date) where tag_no = 'IT-0042'), 'Chemistry', 'AC1: as at 2026-05-01 the Chemistry department held the laptop');
select is((select custodian_name from public.v_asset_custody_asof('2026-08-01'::date) where tag_no = 'IT-0042'), 'Physics', 'AC1: and by August it was with Physics');
select is((select count(*) from public.v_asset_custody_asof('2026-02-01'::date) where tag_no = 'IT-0042'), 0::bigint, 'AC1: before it was issued nobody had it');
select is((select count(*) from public.asset_custody where asset_id = :'laptop'::uuid), 2::bigint, 'AC1: both stints are kept as history');

-- ── AC2: one open custody per asset ───────────────────────────────────────
select throws_ok(format($$ select public.issue_asset_custody(%L, 'department', %L) $$, :'laptop', :'dept_chem'), 'ASSET_IN_CUSTODY', 'AC2: issuing a held asset to a second custodian is refused with ASSET_IN_CUSTODY');
select is((select count(*) from pg_indexes where indexname = 'uq_open_custody'), 1::bigint, 'AC2: enforced by the partial unique index uq_open_custody');
select throws_ok(format($$ select public.return_asset_custody(%L, 'broken') $$, :'c2'), 'CONDITION_INVALID', 'a return needs a recognised condition');

-- ── AC3: exit clearance is blocked while assets are out ───────────────────
select public.issue_asset_custody(:'tablet'::uuid, 'staff', null, null, :'leaver'::uuid, '2026-02-01'::date) as s1 \gset
select public.issue_asset_custody(:'camera'::uuid, 'staff', null, null, :'leaver'::uuid, '2026-02-01'::date) as s2 \gset
select public.issue_asset_custody(:'printer'::uuid, 'staff', null, null, :'leaver'::uuid, '2026-02-01'::date) as s3 \gset
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.assert_staff_asset_clearance(%L) $$, :'leaver'), 'ASSET_CLEARANCE_BLOCKED', 'AC3: clearance is blocked for a staff member holding assets');
select is(jsonb_array_length(public.staff_asset_clearance(:'leaver'::uuid) -> 'assets'), 3, 'AC3: the 3 assets are listed');
select is((select string_agg(x ->> 'tag_no' || ' ' || (x ->> 'name'), ', ' order by x ->> 'tag_no') from jsonb_array_elements(public.staff_asset_clearance(:'leaver'::uuid) -> 'assets') x), 'IT-0043 Tablet, IT-0044 Camera, IT-0045 Printer', 'AC3: by tag and name');
reset role;
select throws_ok(format($$ update public.staff set employment_status = 'exited' where id = %L $$, :'leaver'), 'ASSET_CLEARANCE_BLOCKED', 'AC3: the HR exit itself cannot complete while assets are out');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.return_asset_custody(:'s1'::uuid, 'good');
select public.return_asset_custody(:'s2'::uuid, 'fair');
select public.return_asset_custody(:'s3'::uuid, 'good');
select is((public.staff_asset_clearance(:'leaver'::uuid) ->> 'cleared')::boolean, true, 'once everything is returned the staff member is cleared');
reset role;
select lives_ok(format($$ update public.staff set employment_status = 'exited' where id = %L $$, :'leaver'), 'and the exit goes through');

-- ── AC4: OTP acknowledgement, then the row is frozen ──────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_asset_custody(:'tablet'::uuid, 'staff', null, null, :'hod_staff'::uuid, '2026-08-01'::date) as c3 \gset
select public.request_custody_ack_otp(:'c3'::uuid);
reset role;
select code as otp from public.asset_custody_otp_dispatch where custody_id = :'c3' \gset
select is((select code_hash <> :'otp' from public.asset_custody_otp where custody_id = :'c3'), true, 'the OTP is stored only as a hash');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hod_uid', 'tenant_id', :'tenant_id', 'app_role', 'head_of_department', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.acknowledge_asset_custody(%L, 'otp', '000000x') $$, :'c3'), 'OTP_INVALID', 'a wrong code is refused');
select public.acknowledge_asset_custody(:'c3'::uuid, 'otp', :'otp');
select is((select ack_method::text from public.asset_custody where id = :'c3'::uuid), 'otp', 'AC4: the acknowledgement method is stored');
select ok((select acknowledged_at is not null from public.asset_custody where id = :'c3'::uuid), 'AC4: and the timestamp');
reset role;
select throws_ok(format($$ update public.asset_custody set remarks = 'edited' where id = %L $$, :'c3'), 'CUSTODY_ACKNOWLEDGED_IMMUTABLE', 'AC4: an acknowledged row is no longer editable');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.acknowledge_asset_custody(%L, 'otp', '123456') $$, :'c3'), 'CUSTODY_NOT_ACKNOWLEDGEABLE', 'an acknowledged row cannot be acknowledged again');
select throws_ok(format($$ select public.acknowledge_asset_custody(%L, 'paper') $$, :'c2'), 'REFERENCE_REQUIRED', 'a paper acknowledgement needs the form reference');
select lives_ok(format($$ select public.acknowledge_asset_custody(%L, 'paper', p_reference => 'REG-77/2026') $$, :'c2'), 'a paper acknowledgement with a reference is recorded');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.asset_custody), 0::bigint, 'a teacher sees only custody that is theirs');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.asset_custody), 0::bigint, 'another school sees none');

select * from finish();
rollback;
