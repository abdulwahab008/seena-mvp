-- pgTAP tests for FR-D08: biometric punch ingestion pipeline.
begin;
select plan(28);

select public.provision_tenant('test-bio-co', 'Bio Co', 'owner@bio.test');
select id as tenant_id from public.tenant where slug = 'test-bio-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-bio-other', 'Other Bio Co', 'owner@otherbio.test');
select id as other_tenant_id from public.tenant where slug = 'test-bio-other' \gset

select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'hr_uid', 'hr@bio.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@bio.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name)
select :'tenant_id', :'campus_id', 'BIO-' || n, '42101-7654321-' || n, 'male', 'Staff ' || n from generate_series(1, 8) n;
select id as s1 from public.staff where employee_code = 'BIO-1' and tenant_id = :'tenant_id' \gset
select id as s2 from public.staff where employee_code = 'BIO-2' and tenant_id = :'tenant_id' \gset
select id as s3 from public.staff where employee_code = 'BIO-3' and tenant_id = :'tenant_id' \gset
select id as s4 from public.staff where employee_code = 'BIO-4' and tenant_id = :'tenant_id' \gset
select id as s5 from public.staff where employee_code = 'BIO-5' and tenant_id = :'tenant_id' \gset
select id as s6 from public.staff where employee_code = 'BIO-6' and tenant_id = :'tenant_id' \gset
select id as s7 from public.staff where employee_code = 'BIO-7' and tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select device_id as dev, api_key as dev_key from public.register_biometric_device(:'campus_id'::uuid, 'ZK-TEST-0001', 'Main gate') \gset
select device_id as dev2 from public.register_biometric_device(:'campus_id'::uuid, 'ZK-TEST-0002', 'Annex') \gset
select public.set_biometric_device_clock_offset(:'dev2'::uuid, 600); -- the annex clock runs 10 minutes fast
select public.map_staff_device_code(:'dev'::uuid, '101', :'s1'::uuid);
select public.map_staff_device_code(:'dev'::uuid, '102', :'s2'::uuid);
select public.map_staff_device_code(:'dev'::uuid, '103', :'s3'::uuid);
select public.map_staff_device_code(:'dev'::uuid, '104', :'s4'::uuid);
select public.map_staff_device_code(:'dev'::uuid, '105', :'s5'::uuid);
select public.map_staff_device_code(:'dev2'::uuid, '201', :'s6'::uuid);
reset role;

-- ── AC1: a 500-punch batch posted twice leaves 500 punches and one attendance row ──
select jsonb_agg(jsonb_build_object('code', '101', 'time', to_char(timestamp '2026-08-03 08:00:00' + (i || ' minutes')::interval, 'YYYY-MM-DD"T"HH24:MI:SS') || '+05:00', 'direction', 'unknown')) as b500
  from generate_series(0, 499) i \gset
select public.ingest_biometric_punches(:'dev'::uuid, :'b500'::jsonb) as r1 \gset
select public.ingest_biometric_punches(:'dev'::uuid, :'b500'::jsonb) as r2 \gset
select is((:'r1'::jsonb ->> 'inserted')::int, 500, 'AC1: the first post inserts 500 punches');
select is((:'r2'::jsonb ->> 'inserted')::int, 0, 'AC1: the retried post inserts none');
select is((select count(*) from public.staff_biometric_punch where device_id = :'dev'::uuid), 500::bigint, 'AC1: the punch table holds 500 rows after both calls');
select is((select count(*) from public.staff_attendance where staff_id = :'s1'::uuid and att_date = '2026-08-03'), 1::bigint, 'AC1: zero duplicate attendance rows');
select is((select status::text from public.staff_attendance where staff_id = :'s1'::uuid and att_date = '2026-08-03'), 'present', 'a punch at 08:00 is present');
select is((select anomaly from public.staff_attendance where staff_id = :'s1'::uuid and att_date = '2026-08-03'), null, 'a day with a later sign-out has no anomaly');

-- ── AC2: 08:00 start with a 10 minute grace ──────────────────────────────
select public.ingest_biometric_punches(:'dev'::uuid, '[
  {"code":"102","time":"2026-08-03T08:11:00+05:00","direction":"in"},{"code":"102","time":"2026-08-03T15:00:00+05:00","direction":"out"},
  {"code":"103","time":"2026-08-03T08:09:00+05:00","direction":"in"},{"code":"103","time":"2026-08-03T15:00:00+05:00","direction":"out"},
  {"code":"104","time":"2026-08-03T08:10:00+05:00","direction":"in"},{"code":"104","time":"2026-08-03T15:00:00+05:00","direction":"out"}]'::jsonb);
select is((select status::text from public.staff_attendance where staff_id = :'s2'::uuid and att_date = '2026-08-03'), 'late', 'AC2: first punch 08:11 is late');
select is((select status::text from public.staff_attendance where staff_id = :'s3'::uuid and att_date = '2026-08-03'), 'present', 'AC2: first punch 08:09 is present');
select is((select status::text from public.staff_attendance where staff_id = :'s4'::uuid and att_date = '2026-08-03'), 'present', 'AC2: 08:10 sharp is still within the grace period');

-- ── AC3: an in punch and a dead device => present with an exception, not absent ──
select public.ingest_biometric_punches(:'dev'::uuid, '[{"code":"105","time":"2026-08-03T07:55:00+05:00","direction":"in"}]'::jsonb);
select is((select status::text from public.staff_attendance where staff_id = :'s5'::uuid and att_date = '2026-08-03'), 'present', 'AC3: 07:55 in with no out punch is present');
select is((select anomaly from public.staff_attendance where staff_id = :'s5'::uuid and att_date = '2026-08-03'), 'missing_out_punch', 'AC3: flagged missing_out_punch');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.list_biometric_exceptions(:'campus_id'::uuid, '2026-08-03', '2026-08-03') where staff_id = :'s5'::uuid), 1::bigint, 'AC3: the row is on the exceptions list');
reset role;

-- ── AC4: an unknown code is parked; the rest of the batch still lands ────
select public.ingest_biometric_punches(:'dev'::uuid, '[
  {"code":"999","time":"2026-08-04T09:00:00+05:00","direction":"in"},{"code":"102","time":"2026-08-04T08:00:00+05:00","direction":"in"},
  {"code":"","time":"2026-08-04T08:00:00+05:00"},{"code":"102","time":"not a time"}]'::jsonb) as r4 \gset
select is((:'r4'::jsonb ->> 'unmatched')::int, 1, 'AC4: the unmapped code is counted as unmatched');
select is((:'r4'::jsonb ->> 'inserted')::int, 1, 'AC4: the other punch in the batch is still ingested');
select is((:'r4'::jsonb ->> 'rejected')::int, 2, 'malformed entries are rejected individually, not the whole batch');
select is((select count(*) from public.biometric_unmatched_punch where staff_device_code = '999' and tenant_id = :'tenant_id'), 1::bigint, 'AC4: the unmatched punch waits in the unmatched queue');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.map_staff_device_code(:'dev'::uuid, '999', :'s7'::uuid);
reset role;
select is((select count(*) from public.staff_attendance where staff_id = :'s7'::uuid and att_date = '2026-08-04'), 1::bigint, 'mapping the code later releases the parked punch and derives the day');

-- ── drift, late batches, precedence, size cap ────────────────────────────
select public.ingest_biometric_punches(:'dev2'::uuid, '[{"code":"201","time":"2026-08-03T08:11:00+05:00","direction":"in"},{"code":"201","time":"2026-08-03T16:00:00+05:00","direction":"out"}]'::jsonb);
select is((select status::text from public.staff_attendance where staff_id = :'s6'::uuid and att_date = '2026-08-03'), 'present', 'a 10-minute fast device clock is corrected: 08:11 on the device is 08:01 for real');
select public.ingest_biometric_punches(:'dev'::uuid, '[{"code":"102","time":"2026-07-20T09:00:00+05:00","direction":"in"}]'::jsonb);
select is((select count(*) from public.staff_attendance where staff_id = :'s2'::uuid and att_date = '2026-07-20'), 1::bigint, 'a batch arriving weeks late derives the day it belongs to, not today');

insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source) values
  (:'tenant_id', :'campus_id', :'s2', '2026-08-05', 'absent', 'manual'), (:'tenant_id', :'campus_id', :'s3', '2026-08-05', 'on_leave', 'leave');
select public.ingest_biometric_punches(:'dev'::uuid, '[{"code":"102","time":"2026-08-05T08:00:00+05:00","direction":"in"},{"code":"103","time":"2026-08-05T08:00:00+05:00","direction":"in"}]'::jsonb);
select is((select status::text from public.staff_attendance where staff_id = :'s2'::uuid and att_date = '2026-08-05'), 'absent', 'the device does not overwrite a row a human marked by hand');
select is((select status::text from public.staff_attendance where staff_id = :'s3'::uuid and att_date = '2026-08-05'), 'on_leave', 'the device never overrides an approved leave');

select throws_ok(format($$ select public.ingest_biometric_punches(%L::uuid, (select jsonb_agg(jsonb_build_object('code', '101', 'time', '2026-09-01T08:00:00+05:00')) from generate_series(1, 1001))) $$, :'dev'), 'BATCH_TOO_LARGE', 'at most 1000 punches per call');

-- ── access control ───────────────────────────────────────────────────────
select is((select api_key_hash from public.biometric_device where id = :'dev'::uuid), encode(extensions.digest(:'dev_key', 'sha256'), 'hex'), 'only sha256 of the raw key is stored');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select api_key_hash from public.biometric_device $$, '42501', null, 'the key hash cannot be read by any signed-in user');
select is((select count(*) from public.staff_biometric_punch), 0::bigint, 'punch tables are invisible to signed-in users (service role only)');
select throws_ok(format($$ select public.ingest_biometric_punches(%L::uuid, '[]'::jsonb) $$, :'dev'), '42501', null, 'a signed-in user cannot call the ingest function; only the service role can');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.list_biometric_exceptions(%L::uuid, '2026-08-01', '2026-08-31') $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot read the exceptions list');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'hr_manager', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.biometric_device), 0::bigint, 'another school sees none of these devices');

select * from finish();
rollback;
