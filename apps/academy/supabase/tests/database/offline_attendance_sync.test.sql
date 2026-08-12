-- pgTAP tests for FR-G05: offline attendance capture and sync.
begin;
select plan(32);

select public.provision_tenant('test-offline-sync-co', 'Offline Sync Co', 'owner@offlinesyncco.test');
select id as tenant_id from public.tenant where slug = 'test-offline-sync-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@offlinesyncco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'class_teacher', 'Ms. Class Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_user_id'::uuid, current_date - 30);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.create_student(:'campus_id'::uuid, 'Offline Kid One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Offline Kid Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset
select public.create_student(:'campus_id'::uuid, 'Offline Kid Three', '2015-01-01'::date, 'male') as student3_id \gset
select public.enrol_student(:'section_id'::uuid, :'student3_id'::uuid) as enrol3_id \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

-- The AC's own scenario, literally: the register is tapped at 08:20 on
-- the device and does not reach the server until much later.
select gen_random_uuid() as key1 \gset
select ((current_date + time '08:20') at time zone 'Asia/Karachi') as captured1 \gset

-- ── AC2: the same idempotency key three times over ───────────────────

select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent')),
  :'key1'::uuid, :'captured1'::timestamptz
) as sync1 \gset
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent')),
  :'key1'::uuid, :'captured1'::timestamptz
) as sync2 \gset
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, current_date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol2_id', 'status', 'absent')),
  :'key1'::uuid, :'captured1'::timestamptz
) as sync3 \gset

select is(:'sync1'::jsonb ->> 'result', 'applied', 'AC2: the first call for a key applies the register');
select is(
  (:'sync1'::jsonb ->> 'saved')::int, 3,
  'AC2: all 3 active students are written from the one queued submission'
);
select is(:'sync2'::jsonb, :'sync1'::jsonb, 'AC2: the second call returns the ORIGINAL result, byte for byte');
select is(:'sync3'::jsonb, :'sync1'::jsonb, 'AC2: the third call returns the ORIGINAL result too');
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date),
  3,
  'AC2: exactly ONE row set exists after three retries, not three'
);
select is(
  (select count(*)::int from public.attendance_sync_log where idempotency_key = :'key1'::uuid),
  1,
  'AC2: the idempotency ledger holds exactly one row for the key'
);
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol2_id'::uuid and attendance_date = current_date)::text,
  'absent',
  'AC2: the captured exception survived the replay unchanged'
);
select is(
  (select result from public.attendance_sync_log where idempotency_key = :'key1'::uuid)::text,
  'applied',
  'AC2: the ledger records the applied outcome'
);

-- ── AC3: device capture time vs sync time vs provenance ──────────────

select is(
  (select marked_at from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date),
  :'captured1'::timestamptz,
  'AC3: marked_at is the 08:20 device capture time, not the write time'
);
select is(
  (select source from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date)::text,
  'offline_sync',
  'AC3: source records that this arrived through the offline queue'
);
select ok(
  (select synced_at > marked_at from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date),
  'AC3: synced_at is the later server write time, distinct from marked_at'
);
select is(
  (select l.synced_at from public.attendance_sync_log l where l.idempotency_key = :'key1'::uuid),
  (select d.synced_at from public.attendance_day d where d.enrolment_id = :'enrol1_id'::uuid and d.attendance_date = current_date),
  'AC3: the ledger and the written rows agree on exactly when the sync landed'
);
select is(
  (select captured_at from public.attendance_sync_log where idempotency_key = :'key1'::uuid),
  :'captured1'::timestamptz,
  'AC3: the ledger preserves the device capture time it was given'
);

-- An ordinary online submit is untouched by all of this: no ledger row,
-- source stays 'web', synced_at stays null, marked_at is the write time.
-- (A future date, because every past date is already past its own
-- FR-G09 lock window by the time this test runs.)
select public.rpc_bulk_mark_attendance(:'section_id'::uuid, (current_date + 3)::date, '[]'::jsonb) as online_result \gset
select is((:'online_result'::jsonb ->> 'saved')::int, 3, 'the keyless online path still returns its plain {"saved": n}');
select is(
  (select count(*)::int from public.attendance_day
    where attendance_date = current_date + 3 and source = 'web' and synced_at is null),
  3,
  'the keyless online path writes source=web with no synced_at, exactly as before'
);
select is(
  (select count(*)::int from public.attendance_sync_log where attendance_date = current_date + 3),
  0,
  'the keyless online path writes no ledger row at all'
);

-- ── AC4: locked between capture and sync → correction requests ───────

select gen_random_uuid() as key2 \gset
select ((current_date + time '08:20') at time zone 'Asia/Karachi') as captured2 \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.lock_attendance_now(:'section_id'::uuid, (current_date + 1)::date);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, (current_date + 1)::date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol3_id', 'status', 'late')),
  :'key2'::uuid, :'captured2'::timestamptz
) as locked_sync \gset

select is(:'locked_sync'::jsonb ->> 'error', 'attendance_locked', 'AC4: the write is rejected with the literal attendance_locked');
select is(:'locked_sync'::jsonb ->> 'result', 'rejected_locked', 'AC4: the ledger outcome is rejected_locked');
select is(
  (select count(*)::int from public.attendance_day where section_id = :'section_id'::uuid and attendance_date = current_date + 1),
  0,
  'AC4: nothing was written to the locked date'
);
select is(
  (:'locked_sync'::jsonb ->> 'corrections_requested')::int, 3,
  'AC4: the submission is surfaced as correction requests, not silently dropped'
);
select is(
  (select count(*)::int from public.attendance_correction_request
    where attendance_date = current_date + 1 and status = 'pending'),
  3,
  'AC4: one pending FR-G10/G11 correction request per captured mark'
);
select is(
  (select new_status from public.attendance_correction_request
    where enrolment_id = :'enrol3_id'::uuid and attendance_date = current_date + 1)::text,
  'late',
  'AC4: the correction carries the status the teacher actually captured offline'
);
select ok(
  (select reason from public.attendance_correction_request
    where enrolment_id = :'enrol3_id'::uuid and attendance_date = current_date + 1)
  like 'Captured offline at%08:20, synced after this date was locked',
  'AC4: the reason tells the approver when it was captured and why it arrived late'
);

-- Replaying the rejected submission is idempotent too: the teacher's
-- device retries until it gets an answer, and must not multiply requests.
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, (current_date + 1)::date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol3_id', 'status', 'late')),
  :'key2'::uuid, :'captured2'::timestamptz
) as locked_sync2 \gset
select is(:'locked_sync2'::jsonb, :'locked_sync'::jsonb, 'AC4: replaying a rejected submission returns the original rejection');
select is(
  (select count(*)::int from public.attendance_correction_request where attendance_date = current_date + 1),
  3,
  'AC4: the replay did not multiply correction requests'
);

-- ── rejected_stale: the server was re-marked after this was captured ──

select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, (current_date + 2)::date,
  jsonb_build_array(jsonb_build_object('enrolment_id', :'enrol1_id', 'status', 'absent'))
) as fresher_online \gset

select gen_random_uuid() as key3 \gset
select public.rpc_bulk_mark_attendance(
  :'section_id'::uuid, (current_date + 2)::date,
  '[]'::jsonb,
  :'key3'::uuid, (clock_timestamp() - interval '6 hours')
) as stale_sync \gset

select is(:'stale_sync'::jsonb ->> 'result', 'rejected_stale', 'a capture older than the server''s own marks is rejected as stale');
select is(
  (select status from public.attendance_day where enrolment_id = :'enrol1_id'::uuid and attendance_date = current_date + 2)::text,
  'absent',
  'the stale replay did not overwrite the newer server-side mark'
);

-- ── idempotency keys do not leak across tenants ──────────────────────

reset role;
select public.provision_tenant('test-offline-sync-other-co', 'Offline Sync Other Co', 'owner@offlinesyncotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-offline-sync-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner2@offlinesyncotherco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.rpc_bulk_mark_attendance(%L, %L, %L, %L)', :'section_id', current_date, '[]'::jsonb, :'key1'),
  'SECTION_NOT_FOUND',
  'another tenant cannot replay a key against a section it cannot see'
);
select is(
  (select count(*)::int from public.attendance_sync_log),
  0,
  'RLS: another tenant sees zero rows of this tenant''s sync ledger'
);

-- ── RLS: campus scoping inside the owning tenant ─────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', '[]'::json, 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.attendance_sync_log),
  0,
  'RLS: a campus-scoped role with no campus in scope sees no sync ledger rows'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.attendance_sync_log),
  3,
  'RLS: the teacher''s own campus sees its 3 ledger rows'
);
select throws_ok(
  format(
    'insert into public.attendance_sync_log (tenant_id, campus_id, section_id, idempotency_key, attendance_date, payload, captured_at, synced_at, result, response) values (%L, %L, %L, gen_random_uuid(), current_date, %L, now(), now(), %L, %L)',
    :'tenant_id', :'campus_id', :'section_id', '[]'::jsonb, 'applied', '{}'::jsonb
  ),
  '42501'::char(5),
  null::text,
  'RLS: no client can forge a ledger row — the SECURITY DEFINER function is the only writer'
);

select * from finish();
rollback;
