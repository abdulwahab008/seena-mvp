-- pgTAP tests for FR-P03: driver register with licence expiry block.
begin;
select plan(26);

select public.provision_tenant('test-crew-co', 'Crew Co', 'owner@crew.test');
select id as tenant_id from public.tenant where slug = 'test-crew-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-crew-other', 'Other Crew Co', 'owner@othercrew.test');
select id as other_tenant_id from public.tenant where slug = 'test-crew-other' \gset

select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'tm_uid', 'tm@crew.test', 'authenticated', 'authenticated', 'x'), (:'hr_uid', 'hr@crew.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'prin@crew.test', 'authenticated', 'authenticated', 'x'), (:'teacher_uid', 'teacher@crew.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR Manager'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teacher_uid', :'tenant_id', 'class_teacher', 'Class Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.save_transport_vehicle(:'campus_id'::uuid, 'BUS-42', 42) as bus42 \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'VAN-12', 12) as van12 \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'BUS-OLD', 40) as busold \gset
select public.add_vehicle_document(v, t::public.transport_doc_type, '2027-12-31')
  from (values (:'bus42'::uuid), (:'van12'::uuid)) x(v), (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.add_vehicle_document(:'busold'::uuid, 'fitness', '2026-07-01');
select public.add_vehicle_document(:'busold'::uuid, 'insurance', '2027-12-31');
select public.add_vehicle_document(:'busold'::uuid, 'token_tax', '2027-12-31');
select public.save_transport_route(:'campus_id'::uuid, 'R-01', 'North Morning', 'morning') as r1 \gset
select public.save_transport_route(:'campus_id'::uuid, 'R-02', 'South Morning', 'morning') as r2 \gset
select public.save_transport_route(:'campus_id'::uuid, 'R-03', 'East Morning', 'morning') as r3 \gset

select public.save_transport_crew(:'campus_id'::uuid, 'Aslam', '35202-1234567-1', 'driver', '0300-1111111', 'LH-001', 'LTV', '2026-08-15', '2026-06-01') as aslam \gset
select public.save_transport_crew(:'campus_id'::uuid, 'Bashir', '3520298765432', 'driver', null, 'LH-002', 'HTV', '2028-01-01', null) as bashir \gset
select public.save_transport_crew(:'campus_id'::uuid, 'Nazia', '35202-5555555-5', 'attendant') as nazia \gset
select public.save_transport_crew(:'campus_id'::uuid, 'Karim', '35202-6666666-6', 'conductor') as karim \gset

select is((select cnic from public.transport_crew where id = :'bashir'::uuid), '35202-9876543-2', 'a CNIC typed without dashes is stored in the standard format');

-- AC1: LTV licence on a 42-seat bus.
select throws_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'aslam', :'bus42'), 'LICENCE_CLASS_INSUFFICIENT', 'AC1: an LTV licence cannot drive the 42-seat bus');
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-08-10') $$, :'r1', :'bus42', :'aslam'), 'LICENCE_CLASS_INSUFFICIENT', 'AC1: the assignment is refused');
select lives_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'aslam', :'van12'), 'an LTV licence is fine on a 12-seat van');

-- AC2: licence expiring 2026-08-15.
select throws_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-16') $$, :'aslam', :'van12'), 'LICENCE_EXPIRED', 'AC2: a trip on 2026-08-16 is refused');
select lives_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-14') $$, :'aslam', :'van12'), 'AC2: a trip on 2026-08-14 is allowed');
select lives_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-15') $$, :'aslam', :'van12'), 'and the licence is valid on its last day');
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-08-10', '2026-08-20') $$, :'r1', :'van12', :'aslam'), 'LICENCE_EXPIRED', 'an assignment running past the licence expiry is refused');

-- Police verification is a warning, never a block.
select is(public.assert_driver_eligible(:'bashir'::uuid, :'bus42'::uuid, '2026-08-10'), 'POLICE_VERIFICATION_MISSING', 'a missing police verification is returned as a warning');
select public.save_transport_crew(:'campus_id'::uuid, 'Stale', '35202-7777777-7', 'driver', null, 'LH-003', 'PSV', '2029-01-01', '2024-01-01') as stale \gset
select is(public.assert_driver_eligible(:'stale'::uuid, :'bus42'::uuid, '2026-08-10'), 'POLICE_VERIFICATION_STALE', 'a police verification older than a year is a warning, not a block');
select is(public.assert_driver_eligible(:'aslam'::uuid, :'van12'::uuid, '2026-08-10'), null, 'a fresh verification gives no warning');
select throws_ok(format($$ select public.assert_driver_eligible(%L, %L, '2026-08-10') $$, :'nazia', :'van12'), 'NOT_A_DRIVER', 'only a driver can be checked as a driver');
select is((public.assign_transport_trip(:'r1'::uuid, :'bus42'::uuid, :'bashir'::uuid, '2026-08-10', null, :'karim'::uuid, :'nazia'::uuid) ->> 'warning'), 'POLICE_VERIFICATION_MISSING', 'the assignment goes ahead and carries the warning');

-- AC3: duplicate CNIC in the tenant.
select throws_ok(format($$ select public.save_transport_crew(%L, 'Aslam Two', '35202-1234567-1', 'conductor') $$, :'campus_id'), 'DUPLICATE_CNIC', 'AC3: a second crew record with the same CNIC is rejected');
select throws_ok(format($$ select public.save_transport_crew(%L, 'Bad', '35202-12', 'conductor') $$, :'campus_id'), 'CNIC_INVALID', 'a malformed CNIC is rejected');

-- Assignment conflicts: the same driver cannot run two routes in one shift.
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-08-10') $$, :'r2', :'van12', :'bashir'), 'ASSIGNMENT_CONFLICT', 'the same driver cannot cover two morning routes at once');
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-08-10') $$, :'r1', :'van12', :'aslam'), 'ASSIGNMENT_CONFLICT', 'a route has one vehicle and crew at a time');

-- P02 AC2 end to end: a blocked bus is refused, then assigned with a Principal's override, and audited.
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-07-29') $$, :'r3', :'busold', :'bashir'), 'P0001', 'VEHICLE_BLOCKED: fitness certificate expired 28 days ago', 'the expired bus is refused with the number of days');
select throws_ok(format($$ select public.assign_transport_trip(%L, %L, %L, '2026-07-29', null, null, null, 'Spare bus is in the workshop') $$, :'r3', :'busold', :'bashir'), 'FORBIDDEN', 'the Transport Manager cannot override');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.assign_transport_trip(:'r3'::uuid, :'busold'::uuid, :'bashir'::uuid, '2026-07-29', '2026-07-31', null, null, 'Spare bus is in the workshop') as ovr_assign \gset
select ok((select override_id is not null from public.transport_trip_assignment where route_id = :'r3'::uuid), 'the Principal override assigns the trip and links the override');
select is((select (after ->> 'approved_by') || '|' || (after ->> 'reason') from public.audit_log where table_name = 'transport_vehicle_override' and action = 'insert' and (after ->> 'vehicle_id')::uuid = :'busold'::uuid),
  :'prin_uid' || '|Spare bus is in the workshop', 'audit_log records the approver and reason of the override');

-- AC4: CNIC masking by role.
select is((select driver_cnic from public.v_transport_route_crew where route_id = :'r1'::uuid and driver_name = 'Bashir'), '35202-9876543-2', 'AC4: the Principal sees the full CNIC');
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select driver_cnic from public.v_transport_route_crew where route_id = :'r1'::uuid and driver_name = 'Bashir'), '35202-xxxxxxx-2', 'AC4: a class teacher sees the CNIC masked as 35202-xxxxxxx-2');
select is((select count(*) from public.transport_crew), 0::bigint, 'AC4: the crew table itself is closed to a class teacher');
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select cnic from public.v_transport_crew_public where full_name = 'Aslam'), '35202-1234567-1', 'AC4: the HR Manager sees the full CNIC');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'transport_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.v_transport_crew_public), 0::bigint, 'another school sees no crew');

select * from finish();
rollback;
