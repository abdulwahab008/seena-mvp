-- pgTAP tests for FR-P01: bus routes with ordered stops and slab-driven fares.
begin;
select plan(20);

select public.provision_tenant('test-route-co', 'Route Co', 'owner@route.test');
select id as tenant_id from public.tenant where slug = 'test-route-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-route-other', 'Other Route Co', 'owner@otherroute.test');
select id as other_tenant_id from public.tenant where slug = 'test-route-other' \gset

select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'tm_uid', 'tm@route.test', 'authenticated', 'authenticated', 'x'),
  (:'teacher_uid', 'teacher@route.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager'),
  (:'teacher_uid', :'tenant_id', 'class_teacher', 'Class Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.save_transport_route(:'campus_id'::uuid, 'R-04', 'Johar Town Morning', 'morning') as r04 \gset
select public.save_transport_route(:'campus_id'::uuid, 'R-05', 'Model Town Morning', 'morning') as r05 \gset
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B', 'Zone B', 350000, '2026-01-01') as slab_b \gset

-- 12 stops on R-04, appended in order.
select public.add_transport_stop(:'r04'::uuid, 'Stop ' || i, null, null, null, ('06:' || lpad((40 + i)::text, 2, '0'))::time, ('14:' || lpad((i)::text, 2, '0'))::time, :'slab_b'::uuid)
  from generate_series(1, 11) i;
select public.add_transport_stop(:'r04'::uuid, 'Stop 12', 'اسٹاپ بارہ', 31.4697, 74.2728, '06:45', '14:10', :'slab_b'::uuid) as stop12 \gset

select is((select count(*) from public.transport_stop where route_id = :'r04'::uuid), 12::bigint, 'route R-04 has 12 stops');
select is((select array_agg(seq order by seq) from public.transport_stop where route_id = :'r04'::uuid), array[1,2,3,4,5,6,7,8,9,10,11,12], 'sequence numbers run 1..12');

-- AC1: drag stop 7 to position 3.
select id as stop7 from public.transport_stop where route_id = :'r04'::uuid and name = 'Stop 7' \gset
select public.move_transport_stop(:'stop7'::uuid, 3);
select is((select seq from public.transport_stop where id = :'stop7'::uuid), 3, 'AC1: stop 7 now sits at position 3');
select is((select array_agg(name order by seq) from public.transport_stop where route_id = :'r04'::uuid),
  array['Stop 1','Stop 2','Stop 7','Stop 3','Stop 4','Stop 5','Stop 6','Stop 8','Stop 9','Stop 10','Stop 11','Stop 12'], 'AC1: the stops in between shifted down by one');
select is((select count(distinct seq) from public.transport_stop where route_id = :'r04'::uuid), 12::bigint, 'AC1: every sequence number is unique and none is skipped');
select public.move_transport_stop(:'stop7'::uuid, 12);
select is((select array_agg(seq order by seq) from public.transport_stop where route_id = :'r04'::uuid), array[1,2,3,4,5,6,7,8,9,10,11,12], 'moving down also renumbers without gaps');
select public.move_transport_stop(:'stop7'::uuid, 3);

select is((select condeferrable and condeferred from pg_constraint where conname = 'uq_stop_seq'), true, 'AC1: uq_stop_seq is DEFERRABLE INITIALLY DEFERRED');

-- AC2: the same stop name on two routes is permitted.
select lives_ok(format($$ select public.add_transport_stop(%L, 'Stop 7') $$, :'r05'), 'AC2: the same stop name can exist on another route');
select is((select count(*) from public.transport_stop where name = 'Stop 7' and tenant_id = :'tenant_id'), 2::bigint, 'AC2: both routes carry a stop called Stop 7');

-- AC2: the same sequence twice on one route is rejected (checked immediately here).
reset role;
set constraints public.uq_stop_seq immediate;
select throws_ok(format($$ insert into public.transport_stop (tenant_id, campus_id, route_id, seq, name) values (%L, %L, %L, 5, 'Dup') $$, :'tenant_id', :'campus_id', :'r04'),
  '23505', null, 'AC2: a second stop with sequence 5 on the same route is rejected');
set constraints public.uq_stop_seq deferred;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select throws_ok(format($$ select public.save_transport_route(%L, 'R-04', 'Dup code', 'morning') $$, :'campus_id'), 'ROUTE_CODE_EXISTS', 'a route code is unique within the campus');

-- AC3: fare revision re-prices from its effective date, with no per-student edit.
select public.save_fare_slab(:'campus_id'::uuid, 'ZONE-B', 'Zone B', 390000, '2026-09-01');
select is(public.transport_slab_amount(:'slab_b'::uuid, '2026-08-31'), 350000::bigint, 'AC3: August still prices at PKR 3,500');
select is(public.transport_slab_amount(:'slab_b'::uuid, '2026-09-01'), 390000::bigint, 'AC3: from 2026-09-01 the zone prices at PKR 3,900');
select is((select count(*) from public.transport_fare_slab where code = 'ZONE-B' and tenant_id = :'tenant_id'), 2::bigint, 'AC3: the revision is a new dated version, the old one is kept');
select is((select monthly_amount_paisa from public.v_transport_route_sheet where stop_id = :'stop12'::uuid), 390000::bigint, 'AC3: the route sheet shows the fare in force (every stop on the zone, no per-stop edit)');

-- AC4: pickup and drop times appear on the route sheet.
select is((select pickup_time::text || '/' || drop_time::text from public.v_transport_route_sheet where stop_id = :'stop12'::uuid), '06:45:00/14:10:00', 'AC4: pickup 06:45 and drop 14:10 appear on the route sheet');
select is((select count(*) from public.v_transport_route_sheet where route_id = :'r04'::uuid), 12::bigint, 'AC4: the sheet lists every stop of the route');

-- Scope and roles.
select set_config('request.jwt.claims', json_build_object('sub', :'teacher_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_transport_route(%L, 'R-99', 'Nope', 'morning') $$, :'campus_id'), 'FORBIDDEN', 'only the transport office can edit routes');
select is((select count(*) from public.transport_route), 2::bigint, 'staff of the campus can read routes');
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.transport_route), 0::bigint, 'another school sees no routes');

select * from finish();
rollback;
