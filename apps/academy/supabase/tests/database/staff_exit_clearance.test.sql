-- pgTAP tests for FR-D16: staff exit with clearance checklist.
begin;
select plan(24);

select public.provision_tenant('test-exit-co', 'Exit Co', 'owner@exit.test');
select id as tenant_id from public.tenant where slug = 'test-exit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-exit-other', 'Other Exit Co', 'owner@otherexit.test');
select id as other_tenant_id from public.tenant where slug = 'test-exit-other' \gset

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as acc_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as teach2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'h@exit.test', 'authenticated', 'authenticated', 'x'), (:'lib_uid', 'l@exit.test', 'authenticated', 'authenticated', 'x'),
  (:'acc_uid', 'a@exit.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@exit.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@exit.test', 'authenticated', 'authenticated', 'x'), (:'teach2_uid', 't2@exit.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'), (:'acc_uid', :'tenant_id', 'accountant', 'Accountant'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Leaving Teacher'), (:'teach2_uid', :'tenant_id', 'subject_teacher', 'Later Leaver');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', :'teach_uid', 'EX-1', '42101-2222222-1', 'female', 'Leaving Teacher'),
  (:'tenant_id', :'campus_id', :'teach2_uid', 'EX-2', '42101-2222222-2', 'male', 'Later Leaver'),
  (:'tenant_id', :'campus_id', null, 'EX-3', '42101-2222222-3', 'male', 'Fixed Term');
select id as s1 from public.staff where employee_code = 'EX-1' and tenant_id = :'tenant_id' \gset
select id as s2 from public.staff where employee_code = 'EX-2' and tenant_id = :'tenant_id' \gset
select id as s3 from public.staff where employee_code = 'EX-3' and tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_staff_contract(:'s1'::uuid, 'permanent', '2026-04-01'::date, null, 30::smallint, 80000);

-- ── AC4: 30 day notice, resignation 2026-08-20, last day 2026-08-25 => 25 days short ──
select public.initiate_staff_exit(:'s1'::uuid, 'resignation', '2026-08-20'::date, '2026-08-25'::date, 'Moving abroad') as ex \gset
select is((select notice_shortfall_days from public.staff_exit where id = :'ex'::uuid), 25::smallint, 'AC4: a notice shortfall of 25 days is flagged');
select is((select notice_period_days from public.staff_exit where id = :'ex'::uuid), 30::smallint, 'the contractual notice period is snapshotted');
select is((select count(*) from public.staff_clearance_item where exit_id = :'ex'::uuid), 6::bigint, 'the six clearance items are copied from the school''s templates');
select throws_ok(format($$ select public.initiate_staff_exit(%L::uuid, 'resignation', '2026-08-21'::date, '2026-08-30'::date) $$, :'s1'), 'EXIT_ALREADY_OPEN', 'only one exit can be open per person');

-- ── AC2: only the owning department clears an item; HR can waive with a real reason ──
select throws_ok(format($$ select public.clear_exit_item(%L::uuid, 'library_dues') $$, :'ex'), 'NOT_ITEM_OWNER', 'AC2: HR cannot mark library dues cleared');
select set_config('request.jwt.claims', json_build_object('sub', :'acc_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.clear_exit_item(%L::uuid, 'library_dues') $$, :'ex'), 'NOT_ITEM_OWNER', 'AC2: neither can the Accountant');
select public.clear_exit_item(:'ex'::uuid, 'fee_counter_float');
select public.clear_exit_item(:'ex'::uuid, 'loans_advances');
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(format($$ select public.clear_exit_item(%L::uuid, 'library_dues') $$, :'ex'), 'AC2: the Librarian clears library dues');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.clear_exit_item(:'ex'::uuid, 'academic_handover');
select throws_ok(format($$ select public.complete_staff_exit(%L::uuid) $$, :'ex'), 'FORBIDDEN', 'a Principal cannot complete an exit');

-- ── AC1: two items outstanding => completion is blocked and names them ───
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_like(format($$ select public.complete_staff_exit(%L::uuid) $$, :'ex'), 'CLEARANCE_OUTSTANDING: %ID card and uniform returned%', 'AC1: blocked, naming the ID card item');
select throws_like(format($$ select public.complete_staff_exit(%L::uuid) $$, :'ex'), '%Laptop, keys and IT assets returned', 'AC1: and the IT assets item');
select is((select count(*) from public.get_outstanding_clearance_items(:'ex'::uuid)), 2::bigint, 'exactly two items are outstanding');
select throws_ok(format($$ select public.waive_exit_item(%L::uuid, 'it_assets', 'too short') $$, :'ex'), 'WAIVER_REASON_TOO_SHORT', 'AC2: a waiver reason under 10 characters is refused');
select lives_ok(format($$ select public.waive_exit_item(%L::uuid, 'it_assets', 'Laptop lost, recovered from final pay') $$, :'ex'), 'AC2: a waiver with a real reason is accepted');
select public.clear_exit_item(:'ex'::uuid, 'id_card_uniform');

-- ── AC3: completion strips access at once; a cached token is refused ─────
reset role;
insert into auth.sessions (id, user_id, created_at) values (gen_random_uuid(), :'teach_uid', now());
select claims_version as old_cv from public.app_user where user_id = :'teach_uid' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.complete_staff_exit(:'ex'::uuid);
reset role;
select is((select employment_status::text from public.staff where id = :'s1'::uuid), 'exited', 'the staff row is kept and flipped to exited');
select is((select status::text from public.app_user where user_id = :'teach_uid'), 'terminated', 'AC3: the login is terminated');
select is((select count(*) from auth.sessions where user_id = :'teach_uid'), 0::bigint, 'AC3: the person''s sessions are deleted');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'cv', :'old_cv'::int, 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select app.auth_tenant_id() $$, '28000', 'TOKEN_EPOCH_STALE', 'AC3: a token minted before the exit is rejected on its next query');
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.clear_exit_item(%L::uuid, 'library_dues') $$, :'ex'), 'EXIT_ALREADY_COMPLETED', 'a completed exit is closed to further changes');

-- ── completion waits for the last working date (except termination) ──────
select public.initiate_staff_exit(:'s2'::uuid, 'resignation', app.fn_karachi_today(), app.fn_karachi_today() + 20) as ex2 \gset
select public.waive_exit_item(:'ex2'::uuid, code, 'Waived for the date test') from (values ('library_dues'), ('fee_counter_float'), ('loans_advances'), ('it_assets'), ('id_card_uniform'), ('academic_handover')) v(code);
select throws_ok(format($$ select public.complete_staff_exit(%L::uuid) $$, :'ex2'), 'LAST_WORKING_DATE_NOT_REACHED', 'access is not cut before the last working date');

-- ── the contract-expiry job ──────────────────────────────────────────────
reset role;
insert into public.staff_contract (tenant_id, staff_id, contract_type, start_date, end_date) values (:'tenant_id', :'s3', 'contract', '2025-01-01', app.fn_karachi_today() - 1);
select is(public.initiate_contract_expiry_exits(app.fn_karachi_today()), 1, 'the daily job opens an exit for the lapsed fixed-term contract');
select is(public.initiate_contract_expiry_exits(app.fn_karachi_today()), 0, 're-running it opens nothing new');
select is((select exit_type::text from public.staff_exit where staff_id = :'s3'::uuid), 'contract_expiry', 'it is a contract_expiry exit');

-- ── visibility ───────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_exit), 0::bigint, 'a teacher cannot read exits');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'hr_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.staff_exit), 0::bigint, 'another school sees none');

select * from finish();
rollback;
