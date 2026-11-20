-- pgTAP tests: the transport and hostel functions check the caller's campus.
--
-- A principal, transport manager or accountant assigned to one campus could change the transport
-- opt-in of a student of another campus, readmit that campus's struck-off students, post the month's
-- transport and hostel fees for every campus, and read vehicle, driver, price and student answers
-- for it; any signed-in user could search every struck-off student of the school. The hostel
-- gate-pass functions were already campus-checked (through the hostel staff helper); the gate-pass
-- tests here pin that down.
begin;
select plan(45);

select public.provision_tenant('test-tp-campus', 'Transport Campus Co', 'owner@tpcampus.test');
select id as tenant_id from public.tenant where slug = 'test-tp-campus' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'SB', 'South Campus') returning id as campus_b \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as prin_b_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@tpcampus.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'par@tpcampus.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_b_uid', 'pb@tpcampus.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_b_uid', :'tenant_id', 'principal', 'South Principal');

-- the first day of a month that has not started: nothing is posted when an allocation begins then
select (date_trunc('month', current_date) + interval '2 months')::date as future_month \gset

-- ── fixtures, built by the owner, who reaches both campuses ───────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner',
  'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as sec_a \gset
select public.create_section(:'campus_b'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as sec_b \gset
select public.create_student(:'campus_a'::uuid, 'North Pupil', '2012-01-01'::date, 'male') as s_a \gset
select public.create_student(:'campus_b'::uuid, 'South Boarder', '2012-01-01'::date, 'male') as s_boarder \gset
select public.create_student(:'campus_b'::uuid, 'South Rider', '2012-01-01'::date, 'male') as s_rider \gset
select public.create_student(:'campus_b'::uuid, 'South Struck Off', '2012-01-01'::date, 'male', p_b_form_no => '3520212340001') as s_struck \gset
select public.enrol_student(:'sec_a'::uuid, :'s_a'::uuid);
select public.enrol_student(:'sec_b'::uuid, :'s_boarder'::uuid);
select public.enrol_student(:'sec_b'::uuid, :'s_rider'::uuid);
select public.fn_change_student_status(:'s_struck'::uuid, 'struck_off', 'disciplinary');

-- hostel at the South campus: a boarder, a tariff and a gate pass
select public.create_hostel_block(:'campus_b'::uuid, 'SB', 'South Block', 'male', 2, 4) as block_b \gset
select id as bed_b from public.hostel_bed where bed_code = 'SB-101-B1' \gset
select public.allocate_bed(:'s_boarder'::uuid, :'bed_b'::uuid, '2026-01-05');
select public.save_hostel_tariff(:'campus_b'::uuid, 'quad', 800000, 35000, 2000000, '2026-01-01');
select public.issue_gate_pass(:'s_boarder'::uuid, 'Weekend', '2026-08-14T16:00:00+05'::timestamptz, '2026-08-16T20:00:00+05'::timestamptz,
  'Uncle Unknown', '35202-7654321-9', null, 'Father phoned the principal') as gp \gset

-- transport at the South campus: a route, a priced stop, a bus with papers, a driver, and the rider
select public.save_transport_route(:'campus_b'::uuid, 'SR-1', 'South Morning', 'morning') as route_b \gset
select public.save_fare_slab(:'campus_b'::uuid, 'ZONE-S', 'Zone S', 350000, '2026-01-01') as slab_b \gset
select public.add_transport_stop(:'route_b'::uuid, 'South Gate', null, null, null, '06:45', '14:10', :'slab_b'::uuid) as stop_b \gset
select public.save_transport_vehicle(:'campus_b'::uuid, 'BUS-S1', 40) as bus_b \gset
select public.add_vehicle_document(:'bus_b'::uuid, t::public.transport_doc_type, '2030-01-01') from (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.save_transport_crew(:'campus_b'::uuid, 'South Driver', '35202-1111111-1', 'driver', null, 'L1', 'HTV', '2030-01-01', '2026-01-01') as drv_b \gset
select public.assign_transport_trip(:'route_b'::uuid, :'bus_b'::uuid, :'drv_b'::uuid, '2026-08-01');
select public.allocate_transport(:'s_rider'::uuid, :'stop_b'::uuid, :'stop_b'::uuid, :'future_month'::date) as alloc_b \gset
reset role;
select count(*)::int as alloc_lines_before from public.fee_ledger where source_id = :'alloc_b'::uuid \gset
insert into public.guardian (tenant_id, name_en, cnic, auth_user_id, phone_e164, preferred_language)
values (:'tenant_id', 'South Father', '35202-1234567-1', :'parent_uid', '+923001112233', 'en');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'s_boarder'::uuid, id, 'father', true, true from public.guardian where cnic = '35202-1234567-1';
select is(:'alloc_lines_before'::int, 0, 'fixture: the rider''s allocation starts in a future month, so nothing is posted yet');

-- ── a transport manager of the North campus ───────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'transport_manager',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.fn_set_transport_optin(%L, %L, true) $$, :'s_rider', :'session_id'), 'STUDENT_NOT_FOUND', 'cannot change the transport opt-in of a South student');
select lives_ok(format($$ select public.fn_set_transport_optin(%L, %L, true) $$, :'s_a', :'session_id'), 'but can for a North student');
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, :'bus_b'), 'FORBIDDEN', 'cannot ask whether a South bus is roadworthy');
select throws_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'drv_b', :'bus_b'), 'FORBIDDEN', 'nor whether a South driver is eligible');
select throws_ok(format($$ select public.prorate_transport_fee(%L, %L) $$, :'alloc_b', :'future_month'), 'ALLOCATION_NOT_FOUND', 'cannot price a South allocation');
select is(public.transport_slab_amount(:'slab_b'::uuid, '2026-08-31'), null, 'a South fare slab does not exist for them');
select is(public.post_transport_charges(:'future_month'::date), 0, 'posting the month''s transport charges posts nothing for the South campus');
reset role;
select is((select count(*)::int from public.fee_ledger where source_id = :'alloc_b'::uuid), 0, 'and the South rider''s ledger has no new line');

-- ── a transport manager of the South campus ───────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'transport_manager',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select lives_ok(format($$ select public.fn_set_transport_optin(%L, %L, true) $$, :'s_rider', :'session_id'), 'changes the transport opt-in of a South student');
select lives_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, :'bus_b'), 'asks about a South bus');
select lives_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'drv_b', :'bus_b'), 'and about a South driver');
select ok(public.prorate_transport_fee(:'alloc_b'::uuid, :'future_month'::date) > 0, 'prices a South allocation');
select is(public.transport_slab_amount(:'slab_b'::uuid, '2026-08-31'), 350000::bigint, 'and a South fare slab');
select cmp_ok(public.post_transport_charges(:'future_month'::date), '>=', 1, 'and posts the South campus''s transport charges');
reset role;
select is((select count(*)::int from public.fee_ledger where source_id = :'alloc_b'::uuid), 1, 'which land on the rider''s ledger');

-- ── a teacher: none of these are theirs ──────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'class_teacher',
  'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select throws_ok(format($$ select public.assert_vehicle_roadworthy(%L, '2026-08-10') $$, :'bus_b'), 'FORBIDDEN', 'a teacher cannot ask about a bus');
select throws_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'drv_b', :'bus_b'), 'FORBIDDEN', 'nor about a driver');
select throws_ok(format($$ select public.prorate_transport_fee(%L, %L) $$, :'alloc_b', :'future_month'), 'FORBIDDEN', 'nor price an allocation');
select throws_ok(format($$ select public.transport_slab_amount(%L, '2026-08-31') $$, :'slab_b'), 'FORBIDDEN', 'nor a fare slab');
select throws_ok(format($$ select * from public.fn_find_readmission_candidates(p_b_form_no => '3520212340001') $$), 'FORBIDDEN', 'nor search the struck-off students of the school');
select throws_ok(format($$ select public.billable_mess_days(%L, '2026-08-01') $$, :'s_boarder'), 'FORBIDDEN', 'nor read a boarder''s mess days');
select throws_ok(format($$ select public.assert_bed_gender(%L, %L) $$, :'s_boarder', :'bed_b'), 'FORBIDDEN', 'nor compare a boarder''s gender with a bed');
select throws_ok(format($$ select public.close_gate_pass(%L) $$, :'gp'), 'FORBIDDEN', 'nor close a gate pass');

-- ── readmission: a principal reaches only their own campus ─────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.fn_find_readmission_candidates(p_b_form_no => '3520212340001')), 0, 'a North principal does not find a South struck-off student');
select throws_ok(format($$ select public.fn_readmit_student(%L, %L) $$, :'s_struck', :'sec_a'), 'STUDENT_NOT_FOUND', 'and cannot readmit them');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_b_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from public.fn_find_readmission_candidates(p_b_form_no => '3520212340001')), 1, 'a South principal finds them');
select throws_ok(format($$ select public.fn_readmit_student(%L, %L) $$, :'s_struck', :'sec_a'), 'SECTION_NOT_FOUND', 'but cannot readmit them into a North section');
select lives_ok(format($$ select public.fn_readmit_student(%L, %L) $$, :'s_struck', :'sec_b'), 'and readmits them into a South section');

-- ── a parent of a South boarder ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select throws_ok(format($$ select * from public.fn_find_readmission_candidates(p_name_en => 'South Struck Off', p_dob => '2012-01-01'::date) $$), 'FORBIDDEN', 'a parent cannot search struck-off students');
select is(public.billable_mess_days(:'s_boarder'::uuid, '2026-08-01'), 31, 'but reads their own child''s billable mess days');
select throws_ok(format($$ select public.billable_mess_days(%L, '2026-08-01') $$, :'s_a'), 'FORBIDDEN', 'and not another family''s');

-- ── hostel: the posting and the read-only answers follow the campus ───────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select is(public.post_hostel_charges('2026-08-01'), 0, 'a North accountant posts no hostel charges for the South campus');
select throws_ok(format($$ select public.billable_mess_days(%L, '2026-08-01') $$, :'s_boarder'), 'FORBIDDEN', 'and reads no South boarder''s mess days');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'accountant',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select is(public.post_hostel_charges('2026-08-01'), 3, 'a South accountant posts the boarder''s room, mess and deposit lines');
select is(public.billable_mess_days(:'s_boarder'::uuid, '2026-08-01'), 31, 'and reads the boarder''s mess days');
select is(public.post_hostel_charges('2026-08-01'), 0, 'posting again writes nothing');

-- ── gate passes: already campus-checked, pinned here ──────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.issue_gate_pass(%L, 'Visit', '2026-09-20T16:00:00+05'::timestamptz, '2026-09-20T20:00:00+05'::timestamptz, 'Uncle Unknown', '35202-7654321-9', null, 'Father phoned the principal') $$, :'s_boarder'), 'FORBIDDEN', 'a North principal cannot issue a pass for a South boarder');
select throws_ok(format($$ select public.cancel_gate_pass(%L, 'Plans changed') $$, :'gp'), 'FORBIDDEN', 'cannot cancel a South pass');
select throws_ok(format($$ select public.close_gate_pass(%L) $$, :'gp'), 'FORBIDDEN', 'cannot close a South pass');
select is((select count(*)::int from public.hostel_gate_pass), 0, 'and does not see it');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_b_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal',
  'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select count(*)::int from public.hostel_gate_pass), 1, 'a South principal sees the pass');
select lives_ok(format($$ select public.assert_bed_gender(%L, %L) $$, :'s_boarder', :'bed_b'), 'and compares a boarder''s gender with a bed');
select lives_ok(format($$ select public.close_gate_pass(%L, '2026-08-16T19:00:00+05'::timestamptz) $$, :'gp'), 'and closes it');
reset role;
select is((select status::text from public.hostel_gate_pass where id = :'gp'::uuid), 'returned', 'which marks it returned (the North principal''s attempts changed nothing)');

select * from finish();
rollback;
