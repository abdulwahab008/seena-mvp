-- pgTAP tests for FR-G01: attendance policy configuration per campus.
begin;
select plan(17);

select public.provision_tenant('test-attendance-policy-co', 'Attendance Policy Co', 'owner@attendancepolicyco.test');
select id as tenant_id from public.tenant where slug = 'test-attendance-policy-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── AC1: nothing configured yet ────────────────────────────────────

select is(
  public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid),
  null::jsonb,
  'AC1: no policy row for this campus/session resolves to null'
);
select is(
  public.resolve_attendance_status(:'campus_id'::uuid, :'session_id'::uuid, '08:14'::time),
  null,
  'AC1: attendance status cannot be resolved either — the caller blocks marking on this'
);

-- ── configure the policy ──────────────────────────────────────────

select public.set_attendance_policy(
  p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid,
  p_start_time => '08:00'::time, p_late_threshold_minutes => 15, p_lock_window_hours => 6
) as policy1_id \gset

select ok(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid) ->> 'id')::uuid = :'policy1_id'::uuid,
  'the freshly-configured policy is now the one that resolves'
);
select is(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid) ->> 'lock_window_hours')::int,
  6,
  'the configured lock_window_hours is stored'
);

-- ── AC2: late threshold classification ─────────────────────────────

select is(
  public.resolve_attendance_status(:'campus_id'::uuid, :'session_id'::uuid, '08:14'::time),
  'present',
  'AC2: marked at 08:14 (within the 15-minute threshold of an 08:00 start) resolves Present'
);
select is(
  public.resolve_attendance_status(:'campus_id'::uuid, :'session_id'::uuid, '08:15'::time),
  'present',
  'AC2: exactly on the threshold boundary still resolves Present'
);
select is(
  public.resolve_attendance_status(:'campus_id'::uuid, :'session_id'::uuid, '08:16'::time),
  'late',
  'AC2: one minute past the threshold resolves Late'
);

-- ── AC3: editing lock_window_hours mid-session is effective-dated,
--    not a retroactive rewrite ──────────────────────────────────────

select clock_timestamp() as between_edits \gset

select public.set_attendance_policy(
  p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid,
  p_start_time => '08:00'::time, p_late_threshold_minutes => 15, p_lock_window_hours => 24
) as policy2_id \gset

select is(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid) ->> 'lock_window_hours')::int,
  24,
  'AC3: resolving "now" (no p_as_of) picks up the new lock_window_hours'
);
select is(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid, :'between_edits'::timestamptz) ->> 'lock_window_hours')::int,
  6,
  'AC3: resolving as of a timestamp BEFORE the edit still reports the OLD lock_window_hours — already-locked days are unaffected'
);
select is(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid, :'between_edits'::timestamptz) ->> 'id')::uuid,
  :'policy1_id'::uuid,
  'AC3: that historical resolution is literally the first policy row, not a mutated copy'
);
select ok(
  (select count(*)::int from public.attendance_policy where campus_id = :'campus_id'::uuid and session_id = :'session_id'::uuid) = 2,
  'both policy versions still exist — editing never overwrites history'
);

-- ── AC4: only an admin-tier role can write ─────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  $$ select public.set_attendance_policy(p_campus_id => '00000000-0000-0000-0000-000000000000'::uuid, p_session_id => '00000000-0000-0000-0000-000000000000'::uuid) $$,
  'FORBIDDEN',
  'AC4: an Accountant cannot write the attendance policy'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  $$ select public.set_attendance_policy(p_campus_id => '00000000-0000-0000-0000-000000000000'::uuid, p_session_id => '00000000-0000-0000-0000-000000000000'::uuid) $$,
  'FORBIDDEN',
  'AC4: a Teacher cannot write the attendance policy either'
);
-- A teacher CAN still read it, though — they need the rules to mark against.
select ok(
  (public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid) ->> 'id') is not null,
  'a Teacher can still read the configured policy'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── validation ──────────────────────────────────────────────────────

select throws_ok(
  format('select public.set_attendance_policy(p_campus_id => %L, p_session_id => %L)', gen_random_uuid(), :'session_id'),
  'CAMPUS_NOT_FOUND',
  'an unknown campus is refused'
);

-- ── tenant isolation ────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-attendance-policy-other-co', 'Attendance Policy Other Co', 'owner@attendancepolicyotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-attendance-policy-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@attendancepolicyotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', :'other_user_id')::text,
  true
);
select is(
  public.resolve_attendance_policy(:'campus_id'::uuid, :'session_id'::uuid),
  null::jsonb,
  'AC/defense-in-depth: another tenant cannot resolve this tenant''s policy, even by guessing the campus id'
);
select is(
  (select count(*)::int from public.attendance_policy),
  0,
  'AC/defense-in-depth: another tenant sees zero attendance_policy rows via RLS'
);

select * from finish();
rollback;
