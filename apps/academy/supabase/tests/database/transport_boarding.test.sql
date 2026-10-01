-- pgTAP tests for FR-P05: pickup and drop boarding attendance.
begin;
select plan(21);

select public.provision_tenant('test-board-co', 'Board Co', 'owner@board.test');
select id as tenant_id from public.tenant where slug = 'test-board-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-board-other', 'Other Board Co', 'owner@otherboard.test');
select id as other_tenant_id from public.tenant where slug = 'test-board-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as cond_uid \gset
select gen_random_uuid() as stranger_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@board.test', 'authenticated', 'authenticated', 'x'), (:'tm_uid', 'tm@board.test', 'authenticated', 'authenticated', 'x'),
  (:'cond_uid', 'c@board.test', 'authenticated', 'authenticated', 'x'), (:'stranger_uid', 's@board.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'p@board.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'),
  (:'cond_uid', :'tenant_id', 'receptionist', 'Conductor Account'), (:'stranger_uid', :'tenant_id', 'receptionist', 'Other Staff');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'tm_uid', :'tenant_id', :'campus_id');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, gender, full_name, cnic)
values (:'tenant_id', :'campus_id', :'cond_uid', 'E-COND-1', 'male', 'Conductor Account', '35202-2222222-2');

create temp table stu (n int primary key, sid uuid, eid uuid);
grant all on stu to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 80) as section_id \gset
insert into stu (n, sid) select i, public.create_student(:'campus_id'::uuid, 'Child ' || i, '2015-01-01'::date, 'male') from generate_series(1, 40) i;
update stu set eid = public.enrol_student(:'section_id'::uuid, sid);

select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_transport_route(:'campus_id'::uuid, 'R-07', 'Cantt Morning', 'morning') as r07 \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-A', 'Zone A', 300000, '2026-01-01') as za \gset
select public.add_transport_stop(:'r07'::uuid, 'Liberty Roundabout', 'لبرٹی چوک', null, null, '06:50', '14:00', :'za'::uuid) as stop1 \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'BUS-40', 45) as bus \gset
select public.add_vehicle_document(:'bus'::uuid, t::public.transport_doc_type, '2030-01-01') from (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.save_transport_crew(:'campus_id'::uuid, 'Driver', '35202-1111111-1', 'driver', null, 'L1', 'HTV', '2030-01-01', '2026-01-01') as drv \gset
reset role;
select public.save_transport_crew(:'campus_id'::uuid, 'Conductor', '35202-2222222-2', 'conductor') as cond_crew \gset
update public.transport_crew set staff_id = (select id from public.staff where user_id = :'cond_uid') where id = :'cond_crew';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.assign_transport_trip(:'r07'::uuid, :'bus'::uuid, :'drv'::uuid, '2026-08-01', null, :'cond_crew'::uuid);
select public.allocate_transport(sid, :'stop1'::uuid, :'stop1'::uuid, '2026-08-01') from stu order by n;
select is((select count(*) from public.transport_allocation), 40::bigint, 'a 40-student manifest is allocated to the route');

-- Parent of child 1 (Urdu) and child 2 (English).
reset role;
insert into public.guardian (tenant_id, name_en, auth_user_id, phone_e164, preferred_language) values (:'tenant_id', 'Urdu Parent', :'parent_uid', '+923001234567', 'ur');
insert into public.guardian (tenant_id, name_en, phone_e164, preferred_language) values (:'tenant_id', 'English Parent', '+923007654321', 'en');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', (select sid from stu where n = 1), id, 'father', true, true from public.guardian where name_en = 'Urdu Parent';
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', (select sid from stu where n = 2), id, 'father', true, true from public.guardian where name_en = 'English Parent';

-- Conductor opens the pickup leg and caches the manifest.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'cond_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.open_trip_leg(:'r07'::uuid, '2026-09-14', 'pickup') as pick \gset
select public.open_trip_leg(:'r07'::uuid, '2026-09-14', 'drop') as drop_leg \gset
select is(jsonb_array_length(public.get_leg_manifest(:'pick'::uuid)), 40, 'the conductor''s manifest lists all 40 students');
select is(public.open_trip_leg(:'r07'::uuid, '2026-09-14', 'pickup'), :'pick'::uuid, 'opening the same leg twice returns the same leg');

-- AC1: one batch, 37 boarded + 3 exceptions.
create temp table batch (j jsonb);
grant all on batch to authenticated;
insert into batch
select jsonb_agg(jsonb_build_object('device_event_id', gen_random_uuid(), 'trip_leg_id', :'pick', 'student_id', sid,
                  'state', case when n in (5, 6, 7) then 'absent' else 'boarded' end, 'marked_at', '2026-09-14T01:50:00Z'))
  from stu;
select is(jsonb_array_length((select j from batch)), 40, 'AC1: the batch covers the whole manifest (mark-all-boarded plus 3 exceptions)');
select is((public.sync_boarding_batch((select j from batch)) ->> 'inserted')::int, 40, 'AC1: one call stores the leg');
select is((select count(*) from public.transport_boarding_event where trip_leg_id = :'pick'::uuid and state = 'absent'), 3::bigint, 'AC1: three students are marked absent');

-- AC2: the same batch retried three times stores exactly one event per student.
select is((public.sync_boarding_batch((select j from batch)) ->> 'duplicates')::int, 40, 'AC2: a retried batch is recognised as duplicates');
select public.sync_boarding_batch((select j from batch));
select public.sync_boarding_batch((select j from batch));
select is((select count(*) from public.transport_boarding_event where trip_leg_id = :'pick'::uuid), 40::bigint, 'AC2: after 3 retries there is still exactly one event per student');
select is((select count(distinct device_event_id) from public.transport_boarding_event where trip_leg_id = :'pick'::uuid), 40::bigint, 'AC2: each keyed by its client-generated device_event_id');

-- AC4: a committed boarding enqueues a parent message with stop and time in the parent's language.
reset role;
select is((select count(*) from public.message where metadata ->> 'kind' = 'transport_boarding' and tenant_id = :'tenant_id'), 2::bigint, 'AC4: boarding queued a message for each guardian (retries added none)');
select ok((select body like '%Liberty Roundabout%' and body like '%06:50%' and body like 'Child 2 boarded%' from public.message where recipient_phone = '+923007654321'), 'AC4: the English message names the stop and the time (06:50 PKT)');
select ok((select body like '%لبرٹی چوک%' and body like '%06:50%' and body like '%بجے%' from public.message where recipient_phone = '+923001234567'), 'AC4: the Urdu parent gets an Urdu message with the stop and time');
select ok((select status = 'queued' and created_at > now() - interval '60 seconds' from public.message where recipient_phone = '+923007654321'), 'AC4: enqueued within 60 seconds of the commit');

-- Out-of-order marks do not overwrite a newer one.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'cond_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.sync_boarding_batch(jsonb_build_array(jsonb_build_object('device_event_id', gen_random_uuid(), 'trip_leg_id', :'pick', 'student_id', (select sid from stu where n = 1), 'state', 'absent', 'marked_at', '2026-09-14T01:00:00Z'))) ->> 'stale')::int, 1, 'an older mark arriving late is ignored');
select is((select state::text from public.transport_boarding_event where trip_leg_id = :'pick'::uuid and student_id = (select sid from stu where n = 1)), 'boarded', 'and the newer state stands');

-- Only the crew of the leg (or the transport office) can write.
select set_config('request.jwt.claims', json_build_object('sub', :'stranger_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.sync_boarding_batch(jsonb_build_array(jsonb_build_object('device_event_id', gen_random_uuid(), 'trip_leg_id', %L, 'student_id', %L, 'state', 'absent', 'marked_at', '2026-09-14T03:00:00Z'))) $$, :'pick', (select sid from stu where n = 9)), 'FORBIDDEN', 'staff who are not on the leg''s crew cannot write boarding events');

-- AC3: boarded but never dropped by 15:30 raises an alert.
select set_config('request.jwt.claims', json_build_object('sub', :'cond_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.sync_boarding_batch(jsonb_agg(jsonb_build_object('device_event_id', gen_random_uuid(), 'trip_leg_id', :'drop_leg', 'student_id', sid, 'state', 'dropped', 'marked_at', '2026-09-14T09:40:00Z')))
  from stu where n > 2;
reset role;
select is(public.transport_drop_exception_check('2026-09-14'), 2, 'AC3: two students boarded but were never dropped (the 3 absentees were not on board)');
select ok((select body like '%Child 1%' and body like '%Liberty Roundabout%' and body like '%BUS-40%' from public.user_notification where kind = 'transport_drop_exception' and user_id = :'tm_uid' and title like '%Child 1'), 'AC3: the alert names the student, the stop and the vehicle');
select is(public.transport_drop_exception_check('2026-09-14'), 0, 'AC3: the same students are not alerted twice');

-- Parent reads own child only.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.transport_boarding_event), 1::bigint, 'a parent sees only their own child''s boarding event');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'transport_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.transport_boarding_event), 0::bigint, 'another school sees no boarding events');

select * from finish();
rollback;
