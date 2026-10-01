-- pgTAP tests for FR-P06: GPS telemetry ingest hook.
begin;
select plan(24);

select public.provision_tenant('test-gps-co', 'GPS Co', 'owner@gps.test');
select id as tenant_id from public.tenant where slug = 'test-gps-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-gps-other', 'Other GPS Co', 'owner@othergps.test');
select id as other_tenant_id from public.tenant where slug = 'test-gps-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as tm_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@gps.test', 'authenticated', 'authenticated', 'x'), (:'tm_uid', 'tm@gps.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'p@gps.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'tm_uid', :'tenant_id', 'transport_manager', 'Transport Manager');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Tracked Child', '2015-01-01'::date, 'male') as child \gset
select public.enrol_student(:'section_id'::uuid, :'child'::uuid) as child_enrol \gset
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_transport_route(:'campus_id'::uuid, 'R-01', 'Tracked Route', 'morning') as route1 \gset
select public.save_fare_slab(:'campus_id'::uuid, 'Z', 'Zone', 300000, '2026-01-01') as slab \gset
select public.add_transport_stop(:'route1'::uuid, 'Stop A', null, null, null, '07:00', '14:00', :'slab'::uuid) as stop_a \gset
select public.save_transport_vehicle(:'campus_id'::uuid, 'GPS-001', 40) as veh1 \gset
select public.add_vehicle_document(:'veh1'::uuid, t::public.transport_doc_type, '2030-01-01') from (values ('fitness'), ('insurance'), ('token_tax')) y(t);
select public.save_transport_crew(:'campus_id'::uuid, 'Driver', '35202-1111111-1', 'driver', null, 'L1', 'HTV', '2030-01-01', '2026-01-01') as drv \gset
select public.assign_transport_trip(:'route1'::uuid, :'veh1'::uuid, :'drv'::uuid, '2026-01-01');
select public.allocate_transport(:'child'::uuid, :'stop_a'::uuid, :'stop_a'::uuid, '2026-01-05');
select public.save_transport_vehicle(:'campus_id'::uuid, 'GPS-002', 40) as veh2 \gset
reset role;

-- AC1: flag off -> rejected, nothing written.
select throws_ok(format($$ select public.ingest_vehicle_pings(%L, jsonb_build_array(jsonb_build_object('reg_no', 'GPS-001', 'lat', 31.5, 'lng', 74.3, 'device_ts', now()))) $$, :'tenant_id'), 'FEATURE_OFF', 'AC1: with transport_gps off the ingest refuses');
select is((select count(*) from public.transport_vehicle_ping where tenant_id = :'tenant_id'), 0::bigint, 'AC1: and nothing is written');

insert into public.tenant_feature_override (tenant_id, feature_code, enabled) values (:'tenant_id', 'transport_gps', true);

-- Validation and the 100-ping batch cap.
select is(public.ingest_vehicle_pings(:'tenant_id', jsonb_build_array(
    jsonb_build_object('reg_no', 'gps-001', 'lat', 31.50, 'lng', 74.30, 'speed_kmh', 30, 'heading', 90, 'device_ts', now() - interval '20 seconds'),
    jsonb_build_object('reg_no', 'NOPE-999', 'lat', 31.5, 'lng', 74.3, 'device_ts', now()),
    jsonb_build_object('reg_no', 'GPS-001', 'lat', 99, 'lng', 74.3, 'device_ts', now()),
    jsonb_build_object('reg_no', 'GPS-001', 'lat', 31.5, 'lng', 74.3, 'device_ts', now() + interval '1 hour'))),
  jsonb_build_object('accepted', 1, 'duplicates', 0, 'rejected', 3), 'a good ping is accepted; unknown vehicle, bad coordinates and a future timestamp are rejected');
select throws_ok(format($$ select public.ingest_vehicle_pings(%L, (select jsonb_agg(jsonb_build_object('reg_no', 'GPS-001', 'lat', 31.5, 'lng', 74.3, 'device_ts', now() - (g || ' seconds')::interval)) from generate_series(1, 101) g)) $$, :'tenant_id'), 'BATCH_TOO_LARGE', 'a batch of 101 pings is refused');
select is(public.ingest_vehicle_pings(:'tenant_id', jsonb_build_array(jsonb_build_object('reg_no', 'GPS-001', 'lat', 31.50, 'lng', 74.30, 'device_ts', (select pinged_at from public.transport_vehicle_ping limit 1))))
  ->> 'duplicates', '1', 'a ping repeated by the vendor is recognised as a duplicate');

-- AC2: 30 vehicles pinging every 10 seconds for an hour = 10,800 rows.
insert into public.transport_vehicle (tenant_id, campus_id, reg_no, seat_capacity)
select :'tenant_id', :'campus_id', 'FLEET-' || lpad(i::text, 2, '0'), 40 from generate_series(1, 30) i;
create temp table timings (batch int, ms numeric);
create function pg_temp.bench(p_tenant uuid) returns void language plpgsql as $f$
declare
  v_batch jsonb;
  v_start timestamptz;
  i int;
  v_veh record;
  v_n int := 0;
  v_base timestamptz := date_trunc('second', now()) - interval '1 hour';
begin
  for v_veh in select reg_no from public.transport_vehicle where tenant_id = p_tenant and reg_no like 'FLEET-%' order by reg_no loop
    for i in 0 .. 3 loop
      select jsonb_agg(jsonb_build_object('reg_no', v_veh.reg_no, 'lat', 31.5 + g * 0.0001, 'lng', 74.3 + g * 0.0001, 'speed_kmh', 40, 'heading', 90,
                                          'device_ts', v_base + ((i * 100 + g) * 10 || ' seconds')::interval))
        into v_batch from generate_series(0, case when i = 3 then 59 else 99 end) g;
      v_start := clock_timestamp();
      perform public.ingest_vehicle_pings(p_tenant, v_batch);
      v_n := v_n + 1;
      insert into timings values (v_n, extract(epoch from clock_timestamp() - v_start) * 1000);
    end loop;
  end loop;
end $f$;
select pg_temp.bench(:'tenant_id');
select is((select count(*) from public.transport_vehicle_ping p join public.transport_vehicle v on v.id = p.vehicle_id where v.reg_no like 'FLEET-%'), 10800::bigint, 'AC2: 30 vehicles x 360 pings = 10,800 rows ingested');
select ok((select percentile_cont(0.95) within group (order by ms) from timings) < 300, 'AC2: p95 write latency per 100-ping batch is under 300 ms');
select ok((select count(*) from pg_inherits where inhparent = 'public.transport_vehicle_ping'::regclass) >= 14, 'AC2: rows land in daily range partitions (partitions exist ahead of today)');
select ok((select relkind = 'p' from pg_class where oid = 'public.transport_vehicle_ping'::regclass), 'the ping table is range partitioned');
select is((select count(*) from public.transport_vehicle_position_latest where tenant_id = :'tenant_id'), 31::bigint, 'one latest-position row per vehicle (30 fleet + GPS-001)');
select ok((select now() - updated_at < interval '15 seconds' from public.transport_vehicle_position_latest where vehicle_id = :'veh1'::uuid), 'AC4: the latest position is no more than 15 seconds stale after ingest');

-- Out-of-order pings do not move the latest position backwards.
select public.ingest_vehicle_pings(:'tenant_id', jsonb_build_array(jsonb_build_object('reg_no', 'GPS-001', 'lat', 20.0, 'lng', 70.0, 'device_ts', now() - interval '2 hours')));
select is((select lat from public.transport_vehicle_position_latest where vehicle_id = :'veh1'::uuid), 31.500000::numeric, 'an older ping arriving late is stored but does not rewind the live position');

-- AC3: retention. A 40-day-old raw ping is purged, the daily summary is kept.
select app.fn_ensure_ping_partition(((now() at time zone 'UTC')::date - 40));
insert into public.transport_vehicle_ping (tenant_id, vehicle_id, lat, lng, speed_kmh, pinged_at)
select :'tenant_id', :'veh1'::uuid, 31.50 + i * 0.01, 74.30, 55, (((now() at time zone 'UTC')::date - 40)::text || ' 02:00:00+00')::timestamptz + (i || ' minutes')::interval from generate_series(0, 2) i;
select is(public.transport_ping_purge(), 1, 'AC3: the purge job drops the one partition older than 30 days');
select is((select count(*) from public.transport_vehicle_ping where pinged_at < now() - interval '31 days'), 0::bigint, 'AC3: the raw rows past retention are gone');
select is((select ping_count from public.transport_trip_distance_daily where vehicle_id = :'veh1'::uuid and day = ((now() at time zone 'UTC')::date - 40)), 3, 'AC3: the per-vehicle daily summary is retained');
select ok((select distance_km between 2.1 and 2.3 from public.transport_trip_distance_daily where vehicle_id = :'veh1'::uuid and day = ((now() at time zone 'UTC')::date - 40)), 'AC3: with the distance travelled (about 2.2 km)');
select ok((select count(*) from public.transport_vehicle_ping where pinged_at > now() - interval '2 days') > 10000, 'recent pings are untouched by the purge');

-- Device keys.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'tm_uid', 'tenant_id', :'tenant_id', 'app_role', 'transport_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_gps_credential('Vendor webhook') as gps_key \gset
reset role;
select is(public.verify_gps_credential(:'gps_key'), :'tenant_id'::uuid, 'a device key resolves to its school');
select is(public.verify_gps_credential(split_part(:'gps_key', '.', 1) || '.' || repeat('0', 48)), null, 'a wrong secret resolves to nothing');
select is((select count(*) from public.transport_gps_credential where secret_hash = split_part(:'gps_key', '.', 2)), 0::bigint, 'only a hash of the secret is stored');

-- AC4: parents.
insert into public.guardian (tenant_id, name_en, auth_user_id) values (:'tenant_id', 'Tracking Parent', :'parent_uid');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'child'::uuid, id, 'father', true, true from public.guardian where auth_user_id = :'parent_uid';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select array_agg(vehicle_id) from public.transport_vehicle_position_latest), array[:'veh1'::uuid], 'AC4: a parent sees only the vehicle serving their child''s route');
select is((select count(*) from public.transport_vehicle_position_latest where vehicle_id <> :'veh1'::uuid), 0::bigint, 'AC4: any other route''s vehicle is denied by RLS');
select throws_ok($$ select count(*) from public.transport_vehicle_ping $$, '42501', null, 'the raw ping table is not readable by any signed-in user');
select ok(exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'transport_vehicle_position_latest')
          and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'transport_vehicle_ping'), 'only the latest-position table is published to realtime');

select * from finish();
rollback;
