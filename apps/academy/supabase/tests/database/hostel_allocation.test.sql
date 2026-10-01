-- pgTAP tests for FR-Q02: bed allocation without double booking.
begin;
select plan(25);

select public.provision_tenant('test-bed-co', 'Bed Co', 'owner@bed.test');
select id as tenant_id from public.tenant where slug = 'test-bed-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-bed-other', 'Other Bed Co', 'owner@otherbed.test');
select id as other_tenant_id from public.tenant where slug = 'test-bed-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@bed.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'par@bed.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'prin_uid', :'tenant_id', 'principal', 'Principal');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 20, 4) as iq \gset
select id as bed_b3 from public.hostel_bed where bed_code = 'IQ-105-B3' \gset
select id as bed_210 from public.hostel_bed where bed_code = 'IQ-210-B1' \gset
select id as bed_last from public.hostel_bed where bed_code = 'IQ-101-B1' \gset
select public.create_student(:'campus_id'::uuid, 'Student A', '2012-01-01'::date, 'male') as sa \gset
select public.create_student(:'campus_id'::uuid, 'Student B', '2012-01-01'::date, 'male') as sb \gset
select public.create_student(:'campus_id'::uuid, 'Student C', '2012-01-01'::date, 'male') as sc \gset
select public.create_student(:'campus_id'::uuid, 'Student D', '2012-01-01'::date, 'female') as sd \gset
select public.enrol_student(:'section_id'::uuid, :'sa'::uuid) as ea \gset
select public.enrol_student(:'section_id'::uuid, :'sb'::uuid) as eb \gset
select public.enrol_student(:'section_id'::uuid, :'sc'::uuid);
select public.enrol_student(:'section_id'::uuid, :'sd'::uuid);

-- AC1: A takes IQ-105-B3 from 2026-08-01 with no end date.
select public.allocate_bed(:'sa'::uuid, :'bed_b3'::uuid, '2026-08-01') as alloc_a \gset
select is((select status::text from public.hostel_bed where id = :'bed_b3'::uuid), 'occupied', 'the allocated bed is marked occupied');
select throws_ok(format($$ select public.allocate_bed(%L, %L, '2026-09-01') $$, :'sb', :'bed_b3'), 'BED_TAKEN', 'AC1: B cannot take the bed from 2026-09-01 while A''s stay is open');
select public.vacate_bed(:'alloc_a'::uuid, '2026-08-31', 'Moving out');
select lives_ok(format($$ select public.allocate_bed(%L, %L, '2026-09-01') $$, :'sb', :'bed_b3'), 'AC1: once A''s stay is closed on 2026-08-31, B can take it from 2026-09-01');
select throws_ok(format($$ select public.allocate_bed(%L, %L, '2026-08-15') $$, :'sc', :'bed_b3'), 'BED_TAKEN', 'a stay overlapping B''s from the other side is refused as well');

-- The exclusion constraint itself is what guarantees it (a direct insert bypassing the function is refused).
reset role;
select throws_ok(format($$ insert into public.hostel_allocation (tenant_id, campus_id, student_id, enrolment_id, bed_id, starts_on)
  values (%L, %L, %L, (select id from public.enrolment where student_id = %L), %L, '2026-10-01') $$, :'tenant_id', :'campus_id', :'sc', :'sc', :'bed_b3'), '23P01', null, 'AC1/AC2: the GiST exclusion constraint rejects an overlapping insert even without the function');
select ok((select count(*) = 1 from pg_constraint where conname = 'ex_bed_no_overlap' and contype = 'x') and (select count(*) = 1 from pg_constraint where conname = 'ex_student_one_bed' and contype = 'x'), 'both exclusion constraints exist');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- AC2: the last free bed; two requests, one winner. Single-session proof: the second always sees BED_TAKEN.
select public.allocate_bed(:'sc'::uuid, :'bed_last'::uuid, '2026-08-01');
select throws_ok(format($$ select public.allocate_bed(%L, %L, '2026-08-01') $$, :'sa', :'bed_last'), 'BED_TAKEN', 'AC2: the second clerk to ask for the last free bed receives BED_TAKEN');
select is((select count(*) from public.hostel_allocation where bed_id = :'bed_last'::uuid), 1::bigint, 'AC2: exactly one allocation holds the bed');

-- A student cannot hold two beds at once.
select throws_ok(format($$ select public.allocate_bed(%L, %L, '2026-08-10') $$, :'sc', :'bed_210'), 'STUDENT_ALREADY_HOUSED', 'a student already in a bed cannot be given a second one');

-- AC3: transfer from IQ-105-B3 (B) to IQ-210-B1 on 2026-10-05.
select public.transfer_bed(:'sb'::uuid, :'bed_210'::uuid, '2026-10-05') as alloc_b2 \gset
select is((select ends_on from public.hostel_allocation where student_id = :'sb'::uuid and bed_id = :'bed_b3'::uuid), '2026-10-04'::date, 'AC3: the first allocation closes on 2026-10-04');
select is((select starts_on from public.hostel_allocation where id = :'alloc_b2'::uuid), '2026-10-05'::date, 'AC3: the new one opens on 2026-10-05');
select is((select count(distinct student_id) from public.hostel_allocation a where a.student_id = :'sb'::uuid and a.starts_on <= '2026-10-31' and coalesce(a.ends_on, '2999-01-01') >= '2026-10-01'), 1::bigint, 'AC3: October occupancy counts the student once');
select throws_ok(format($$ select public.transfer_bed(%L, %L, '2026-11-01') $$, :'sb', :'bed_last'), 'BED_TAKEN', 'a transfer to an occupied bed is refused');
select is((select ends_on from public.hostel_allocation where id = :'alloc_b2'::uuid), null, 'and leaves the student''s current stay untouched (atomic)');

-- Gender and out-of-service rules at allocation time.
select public.create_hostel_block(:'campus_id'::uuid, 'FT', 'Fatima Block', 'female', 1, 2) as ft \gset
select id as girl_bed from public.hostel_bed where bed_code = 'FT-101-B1' \gset
select throws_ok(format($$ select public.allocate_bed(%L, %L, '2026-08-01') $$, :'sa', :'girl_bed'), 'GENDER_MISMATCH', 'a male student is refused a bed in the girls'' block');
select public.allocate_bed(:'sd'::uuid, :'girl_bed'::uuid, '2026-08-01');
select id as room_b2_room from public.hostel_room where block_id = :'iq'::uuid and room_no = '210' \gset
select public.update_hostel_room(:'room_b2_room'::uuid, 4, 'quad', 'out_of_service');
select is((select count(*) from public.hostel_allocation where bed_id = :'bed_210'::uuid and ends_on is null), 1::bigint, 'Q01 AC4: the existing allocation stays intact when its room goes out of service');
select throws_ok(format($$ select public.allocate_bed(%L, (select id from public.hostel_bed where bed_code = 'IQ-210-B2'), '2026-11-01') $$, :'sa'), 'ROOM_OUT_OF_SERVICE', 'but no new stay can start in an out-of-service room');

-- AC4: withdrawal closes the stay on the leaving date and frees the bed the same night.
reset role;
update public.enrolment set status = 'left', left_on = '2026-11-20' where student_id = :'sc'::uuid;
select is((select ends_on from public.hostel_allocation where student_id = :'sc'::uuid), '2026-11-20'::date, 'AC4: withdrawing the enrolment on 2026-11-20 closes the hostel allocation that day');
select lives_ok(format($$ select public.allocate_bed(%L, %L, '2026-11-21') $$, :'sa', :'bed_last'), 'AC4: the bed can be given to someone else from the day after');
-- Leaving today: the bed is available again the same night.
select public.create_student(:'campus_id'::uuid, 'Student E', '2012-01-01'::date, 'male') as se \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.enrol_student(:'section_id'::uuid, :'se'::uuid);
select id as bed_e from public.hostel_bed where bed_code = 'IQ-102-B1' \gset
select public.allocate_bed(:'se'::uuid, :'bed_e'::uuid, '2026-09-01');
select is((select status::text from public.hostel_bed where id = :'bed_e'::uuid), 'occupied', 'the bed is occupied during the stay');
reset role;
update public.enrolment set status = 'left', left_on = app.fn_karachi_today() - 1 where student_id = :'se'::uuid;
select is((select status::text from public.hostel_bed where id = :'bed_e'::uuid), 'available', 'AC4: a stay whose last night has passed frees the bed immediately');
update public.hostel_bed set status = 'occupied' where id = :'bed_e'::uuid;
select is(public.hostel_bed_status_refresh() >= 1, true, 'AC4: and the nightly job repairs any bed still marked occupied after its stay ended');
select is((select status::text from public.hostel_bed where id = :'bed_e'::uuid), 'available', 'AC4: so the bed is available the same night');

-- Parent reads own child only.
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Boarder Parent', :'parent_uid');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'sb'::uuid, id, 'father', true, true from public.guardian where auth_user_id = :'parent_uid';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(distinct student_id) from public.hostel_allocation), 1::bigint, 'a parent sees only their own child''s hostel allocations');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_allocation), 0::bigint, 'another school sees no allocations');

select * from finish();
rollback;
