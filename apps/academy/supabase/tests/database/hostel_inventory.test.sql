-- pgTAP tests for FR-Q01: hostel block, room and bed inventory.
begin;
select plan(21);

select public.provision_tenant('test-hostel-co', 'Hostel Co', 'owner@hostel.test');
select id as tenant_id from public.tenant where slug = 'test-hostel-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-hostel-other', 'Other Hostel Co', 'owner@otherhostel.test');
select id as other_tenant_id from public.tenant where slug = 'test-hostel-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as warden_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@hostel.test', 'authenticated', 'authenticated', 'x'), (:'warden_uid', 'w@hostel.test', 'authenticated', 'authenticated', 'x'),
  (:'teacher_uid', 't@hostel.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'warden_uid', :'tenant_id', 'receptionist', 'Warden Account'), (:'teacher_uid', :'tenant_id', 'class_teacher', 'Teacher');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, gender, full_name, cnic)
values (:'tenant_id', :'campus_id', :'warden_uid', 'E-WARD-1', 'male', 'Warden Account', '35202-3333333-3');
select id as warden_staff from public.staff where user_id = :'warden_uid' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';

-- AC1: Iqbal Block (Boys), 20 rooms of 4 beds.
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 20, 4, 10, 'quad', :'warden_staff'::uuid) as iq \gset
select is((select count(*) from public.hostel_room where block_id = :'iq'::uuid), 20::bigint, 'AC1: the block has 20 rooms');
select is((select count(*) from public.hostel_bed d join public.hostel_room r on r.id = d.room_id where r.block_id = :'iq'::uuid), 80::bigint, 'AC1: saving the block creates 80 bed rows');
select ok((select count(*) = 1 from public.hostel_bed where bed_code = 'IQ-105-B3'), 'AC1: a bed is identified as IQ-105-B3');
select ok((select count(*) = 1 from public.hostel_bed where bed_code = 'IQ-210-B1'), 'AC1: and IQ-210-B1 (rooms are numbered by floor)');
select throws_ok(format($$ select public.create_hostel_block(%L, 'IQ', 'Again', 'male', 1, 1) $$, :'campus_id'), 'BLOCK_CODE_EXISTS', 'a block code is unique on the campus');

-- AC2: reducing the bed count never regenerates beds, and is refused when the bed is occupied.
select id as room105 from public.hostel_room where block_id = :'iq'::uuid and room_no = '105' \gset
select array_agg(id order by bed_no) as bed_ids_before from public.hostel_bed where room_id = :'room105'::uuid \gset
reset role;
update public.hostel_bed set status = 'occupied' where room_id = :'room105'::uuid and bed_no = 4;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.update_hostel_room(%L, 3, 'quad', 'in_service') $$, :'room105'), 'BED_OCCUPIED', 'AC2: reducing 4 beds to 3 while bed 4 is occupied is refused');
select is((select bed_count from public.hostel_room where id = :'room105'::uuid), 4, 'and the room keeps 4 beds');
reset role;
update public.hostel_bed set status = 'available' where room_id = :'room105'::uuid and bed_no = 4;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.update_hostel_room(:'room105'::uuid, 3, 'triple', 'in_service');
select is((select array_agg(status::text order by bed_no) from public.hostel_bed where room_id = :'room105'::uuid), array['available','available','available','retired'], 'a vacant fourth bed is retired, not deleted');
select public.update_hostel_room(:'room105'::uuid, 4, 'quad', 'in_service');
select is((select array_agg(id order by bed_no) from public.hostel_bed where room_id = :'room105'::uuid), :'bed_ids_before'::uuid[], 'raising it back reuses the very same bed rows (ids unchanged)');
select is((select count(*) from public.hostel_bed where room_id = :'room105'::uuid), 4::bigint, 'no bed rows were regenerated');

-- AC3: gender belongs to the block.
select public.create_hostel_block(:'campus_id'::uuid, 'FT', 'Fatima Block', 'female', 2, 4) as ft \gset
select id as girl_bed from public.hostel_bed where bed_code = 'FT-101-B1' \gset
select id as boy_bed from public.hostel_bed where bed_code = 'IQ-101-B1' \gset
select public.create_student(:'campus_id'::uuid, 'Boy Boarder', '2012-01-01'::date, 'male') as boy \gset
select public.create_student(:'campus_id'::uuid, 'Girl Boarder', '2012-01-01'::date, 'female') as girl \gset
select throws_ok(format($$ select public.assert_bed_gender(%L, %L) $$, :'boy', :'girl_bed'), 'GENDER_MISMATCH', 'AC3: a male student cannot take a bed in the girls'' block');
select throws_ok(format($$ select public.assert_bed_gender(%L, %L) $$, :'girl', :'boy_bed'), 'GENDER_MISMATCH', 'AC3: nor a female student in the boys'' block');
select lives_ok(format($$ select public.assert_bed_gender(%L, %L) $$, :'boy', :'boy_bed'), 'AC3: the matching gender is fine');

-- AC4: out of service removes the beds from the available count.
select beds_available as avail_before from public.v_hostel_occupancy where block_id = :'iq'::uuid \gset
select public.update_hostel_room(:'room105'::uuid, 4, 'quad', 'out_of_service');
select is((select beds_available from public.v_hostel_occupancy where block_id = :'iq'::uuid), :'avail_before'::bigint - 4, 'AC4: the room''s 4 beds leave the available-bed count');
select is((select beds_out_of_service from public.v_hostel_occupancy where block_id = :'iq'::uuid), 4::bigint, 'AC4: and are reported as out of service');
select is((select count(*) from public.hostel_bed where room_id = :'room105'::uuid), 4::bigint, 'AC4: the bed rows themselves are untouched');

select throws_ok(format($$ select public.add_hostel_room(%L, '101', 4) $$, :'iq'), 'ROOM_EXISTS', 'a room number is unique within the block');

-- Who can see and change what.
select set_config('request.jwt.claims', json_build_object('sub', :'warden_uid', 'tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.hostel_block), 2::bigint, 'the warden named on a block can see the hostel');
select throws_ok(format($$ select public.update_hostel_room(%L, 4, 'quad', 'in_service') $$, :'room105'), 'FORBIDDEN', 'but only the Principal side can change rooms');
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.hostel_block), 0::bigint, 'a class teacher sees no hostel data');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_bed), 0::bigint, 'another school sees no beds');

select * from finish();
rollback;
