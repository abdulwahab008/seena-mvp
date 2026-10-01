-- pgTAP tests for FR-P04: stop allocation drives the transport fee.
begin;
select plan(25);

select public.provision_tenant('test-alloc-co', 'Alloc Co', 'owner@alloc.test');
select id as tenant_id from public.tenant where slug = 'test-alloc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-alloc-other', 'Other Alloc Co', 'owner@otheralloc.test');
select id as other_tenant_id from public.tenant where slug = 'test-alloc-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@alloc.test', 'authenticated', 'authenticated', 'x'), (:'tm_uid', 'tm@alloc.test', 'authenticated', 'authenticated', 'x'),
  (:'acct_uid', 'a@alloc.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@alloc.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');

create temp table stu (n int primary key, sid uuid, eid uuid);
grant all on stu to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 80) as section_id \gset
insert into stu (n, sid) select i, public.create_student(:'campus_id'::uuid, 'Rider ' || i, '2015-01-01'::date, 'male') from generate_series(1, 47) i;
update stu set eid = public.enrol_student(:'section_id'::uuid, sid);

-- Route R-04, two zones, a 42-seat bus assigned from 2026-08-01.
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_transport_route(:'campus_id'::uuid, 'R-04', 'Johar Town Morning', 'morning') as r04 \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B', 'Zone B', 350000, '2026-01-01') as zb \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-C', 'Zone C', 420000, '2026-01-01') as zc \gset
select public.add_transport_stop(:'r04'::uuid, 'Gate', null, null, null, '06:45', '14:10', :'zb'::uuid) as stop_b \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B2', 'Zone B (unrevised)', 350000, '2026-01-01') as zb2 \gset
select public.add_transport_stop(:'r04'::uuid, 'Gate Annex', null, null, null, '06:50', '14:05', :'zb2'::uuid) as stop_b2 \gset
select public.add_transport_stop(:'r04'::uuid, 'Far Market', null, null, null, '07:05', '13:50', :'zc'::uuid) as stop_c \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'BUS-42', 42) as bus \gset
select public.add_vehicle_document(:'bus'::uuid, t::public.transport_doc_type, '2030-01-01') from (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.save_transport_crew(:'campus_id'::uuid, 'Driver', '35202-1111111-1', 'driver', null, 'L1', 'HTV', '2030-01-01', '2026-01-01') as drv \gset
select public.assign_transport_trip(:'r04'::uuid, :'bus'::uuid, :'drv'::uuid, '2026-08-01');

-- ── AC2: pro-rata allocation on 2026-08-11 in a 31-day month ────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_transport_setting('transport.prorate', '"prorata"'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select sid as s_a, eid as e_a from stu where n = 1 \gset
select public.allocate_transport(:'s_a'::uuid, :'stop_b'::uuid, :'stop_b'::uuid, '2026-08-11') as alloc_a \gset
select public.post_transport_charges('2026-08-01');
select is((select amount_paisa from public.fee_ledger where source_id = :'alloc_a'::uuid and value_date = '2026-08-01'), 237100::bigint, 'AC2: pro-rata August charge is 3,500 x 21/31 = PKR 2,371');
select is(public.prorate_transport_fee(:'alloc_a'::uuid, '2026-09-01'), 350000::bigint, 'AC2: September onward is the full PKR 3,500');
select is((select count(*) from public.fee_ledger where source_id = :'alloc_a'::uuid and value_date = '2026-08-01'), 1::bigint, 'posting twice does not duplicate the August line');
select is((select f.code from public.fee_ledger l join public.fee_head f on f.id = l.fee_head_id where l.source_id = :'alloc_a'::uuid limit 1), 'TRANSPORT', 'the line is posted to the TRANSPORT head');

-- ── AC3: full-month policy ──────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_transport_setting('transport.prorate', '"full_month"'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select sid as s_b from stu where n = 2 \gset
select public.allocate_transport(:'s_b'::uuid, :'stop_b'::uuid, :'stop_b'::uuid, '2026-08-11') as alloc_b \gset
select public.post_transport_charges('2026-08-01');
select is((select amount_paisa from public.fee_ledger where source_id = :'alloc_b'::uuid and value_date = '2026-08-01'), 350000::bigint, 'AC3: with full-month policy the same allocation charges the full PKR 3,500');

-- ── AC1: seat capacity of the assigned vehicle ──────────────────────────────
select public.allocate_transport(sid, :'stop_b'::uuid, :'stop_b'::uuid, '2026-08-11') from stu where n between 3 and 42 order by n;
select is((select count(*) from public.transport_allocation where route_id = :'r04'::uuid), 42::bigint, 'AC1: 42 students are allocated on the 42-seat bus');
select sid as s43 from stu where n = 43 \gset
select throws_ok(format($$ select public.allocate_transport(%L, %L, %L, '2026-08-11') $$, :'s43', :'stop_b', :'stop_b'), '53400', 'ROUTE_FULL (42/42)', 'AC1: the 43rd student is refused with ROUTE_FULL (42/42)');
select public.join_transport_waitlist(:'s43'::uuid, :'r04'::uuid);
select is((select count(*) from public.transport_waitlist where route_id = :'r04'::uuid and student_id = :'s43'::uuid), 1::bigint, 'AC1: the refused student is queued on the waiting list');
select is((select count(*) from public.transport_allocation where student_id = :'s43'::uuid), 0::bigint, 'and holds no seat');
select throws_ok(format($$ select public.allocate_transport(%L, %L, %L, '2026-07-01') $$, :'s43', :'stop_b', :'stop_b'), 'ROUTE_NO_VEHICLE', 'capacity is read from the vehicle assigned on the start date (none before 2026-08-01)');
reset role;
select throws_ok(format($$ insert into public.transport_allocation (tenant_id, campus_id, student_id, enrolment_id, route_id, pickup_stop_id, drop_stop_id, fare_slab_id, starts_on)
  values (%L, %L, %L, %L, %L, %L, %L, %L, '2026-09-01') $$, :'tenant_id', :'campus_id', :'s_a', :'e_a', :'r04', :'stop_b', :'stop_b', :'zb'), '23P01', null, 'a student cannot hold two overlapping allocations (exclusion constraint)');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── Fee revision re-prices every student on the zone ─────────────────────────
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B', 'Zone B', 390000, '2026-09-01');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.post_transport_charges('2026-09-01');
select is((select count(*) from public.fee_ledger where value_date = '2026-09-01' and source_type = 'transport_allocation' and tenant_id = :'tenant_id' and amount_paisa = 390000), 42::bigint, 'P01 AC3: 42 students on Zone B all re-price to PKR 3,900 in September');
select is((select count(*) from public.fee_ledger where value_date = '2026-08-01' and source_type = 'transport_allocation' and tenant_id = :'tenant_id' and amount_paisa = 350000), 41::bigint, 'and August stays at PKR 3,500');

-- Free some seats for October (service ends 30 September for five riders).
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.end_transport_allocation(a.id, '2026-09-30') from public.transport_allocation a where a.student_id in (select sid from stu where n between 4 and 8);

-- ── AC4: a mid-month move from Zone B to Zone C ──────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select sid as s_c from stu where n = 44 \gset
select public.allocate_transport(:'s_c'::uuid, :'stop_b2'::uuid, :'stop_b2'::uuid, '2026-10-01') as alloc_c \gset
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_transport_setting('transport.prorate', '"prorata"'::jsonb);
select public.post_transport_charges('2026-10-01');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.move_transport_allocation(:'s_c'::uuid, :'stop_c'::uuid, :'stop_c'::uuid, '2026-10-16') as alloc_c2 \gset
reset role;
select is((select ends_on from public.transport_allocation where id = :'alloc_c'::uuid), '2026-10-15'::date, 'AC4: the old allocation closes the day before the move');
select is((select starts_on from public.transport_allocation where id = :'alloc_c2'::uuid), '2026-10-16'::date, 'AC4: the new allocation opens on 2026-10-16');
select is(app.fn_transport_posted(:'alloc_c'::uuid, '2026-10-01'), 169400::bigint, 'AC4: the closing line leaves Zone B at 3,500 x 15/31 = PKR 1,694');
select is(app.fn_transport_posted(:'alloc_c2'::uuid, '2026-10-01'), 216800::bigint, 'AC4: the opening line is Zone C at 4,200 x 16/31 = PKR 2,168');
select ok((app.fn_transport_posted(:'alloc_c'::uuid, '2026-10-01') + app.fn_transport_posted(:'alloc_c2'::uuid, '2026-10-01')) <= 420000, 'AC4: the two lines never exceed PKR 4,200 for October');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
-- Full-month policy: the move cannot make the month cost more than the dearest slab either.
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_transport_setting('transport.prorate', '"full_month"'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select sid as s_e from stu where n = 45 \gset
select public.allocate_transport(:'s_e'::uuid, :'stop_b2'::uuid, :'stop_b2'::uuid, '2026-10-01') as alloc_e \gset
select public.move_transport_allocation(:'s_e'::uuid, :'stop_c'::uuid, :'stop_c'::uuid, '2026-10-16') as alloc_e2 \gset
select is((select sum(case direction when 'debit' then amount_paisa else -amount_paisa end)::bigint from public.fee_ledger where source_id in (:'alloc_e'::uuid, :'alloc_e2'::uuid) and value_date = '2026-10-01'), 420000::bigint, 'full-month policy: a move up a zone costs the dearest slab once, not both');

-- ── Parent reads own child only, with route and stop times ─────────────────
reset role;
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Parent One', :'parent_uid');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'s_a'::uuid, id, 'father', true, true from public.guardian where auth_user_id = :'parent_uid';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.transport_allocation), 1::bigint, 'a parent sees only their own child''s allocation');
select is((select count(*) from public.transport_stop where route_id = :'r04'::uuid), 3::bigint, 'and the stops of that route');
select is((select pickup_time::text from public.transport_stop where id = :'stop_b'::uuid), '06:45:00', 'with the pickup time');

-- ── Withdrawal releases the seat ────────────────────────────────────────────
reset role;
update public.enrolment set status = 'left', left_on = '2026-11-20' where id = (select eid from stu where n = 3);
select is((select ends_on from public.transport_allocation where student_id = (select sid from stu where n = 3)), '2026-11-20'::date, 'withdrawing the enrolment ends the bus allocation on the leaving date');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'transport_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.transport_allocation), 0::bigint, 'another school sees no allocations');
select throws_ok(format($$ select public.allocate_transport(%L, %L, %L, '2026-09-01') $$, :'s43', :'stop_b', :'stop_b'), 'NO_ACTIVE_ENROLMENT', 'another school cannot allocate this student');

select * from finish();
rollback;
