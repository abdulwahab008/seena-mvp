-- pgTAP tests for FR-B11: schedule admission test and allocate seats.
--
-- AC "two officers allocate the last seat simultaneously from two
-- devices... exactly one succeeds" isn't exercised directly — guaranteed
-- by the advisory lock keyed on sitting_id, the same untestable-in-a-
-- single-connection caveat already documented for every other race this
-- codebase closes this way (FR-K10, FR-K16, FR-B07).
begin;
select plan(16);

select public.provision_tenant('test-sitting-co', 'Sitting Co', 'owner@sittingco.test');
select id as tenant_id from public.tenant where slug = 'test-sitting-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-sitting-other-co', 'Sitting Other Co', 'owner@sittingotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-sitting-other-co' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- Two small sittings (capacity 2), so the "full" AC is cheap to trigger.
select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, '2026-08-10 09:00:00+05'::timestamptz, 2) as sitting_a_id \gset
select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, '2026-08-17 09:00:00+05'::timestamptz, 2) as sitting_b_id \gset

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.fn_submit_application(:'enquiry1_id'::uuid) as app1_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Two', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Three', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset

-- ── AC1: full sitting is rejected, no seat consumed ─────────────────

select public.fn_allocate_test_seat(:'sitting_a_id'::uuid, :'app1_id'::uuid) as seat1 \gset
select is(:'seat1'::int, 1, 'the first allocation gets seat 1');
select public.fn_allocate_test_seat(:'sitting_a_id'::uuid, :'app2_id'::uuid) as seat2 \gset
select is(:'seat2'::int, 2, 'AC: seat numbers are contiguous — the second allocation gets seat 2');

select throws_ok(
  format('select public.fn_allocate_test_seat(%L, %L)', :'sitting_a_id', :'app3_id'),
  'SITTING_FULL',
  'AC: a 3rd allocation into a capacity-2 sitting is rejected with the function''s own named error (the human-readable "Sitting full - 2/2" is carried in the exception detail)'
);
select is(
  (select count(*)::int from public.admission_test_candidate where sitting_id = :'sitting_a_id'::uuid and cancelled_at is null),
  2,
  'AC: the rejected allocation consumed no seat — still exactly 2 active candidates'
);

-- ── AC2: reallocating to a different sitting cancels the first ──────

select public.fn_allocate_test_seat(:'sitting_b_id'::uuid, :'app1_id'::uuid) as seat1_in_b \gset
select is(:'seat1_in_b'::int, 1, 'candidate one, reallocated to sitting B, gets seat 1 there');
select is(
  (select cancelled_at is not null from public.admission_test_candidate where sitting_id = :'sitting_a_id'::uuid and application_id = :'app1_id'::uuid),
  true,
  'AC: the original allocation in sitting A is cancelled once reallocated to sitting B'
);
select is(
  (select count(*)::int from public.admission_test_candidate where application_id = :'app1_id'::uuid and cancelled_at is null),
  1,
  'AC: exactly one active allocation exists for the reallocated candidate — the partial unique index holds'
);
select is(
  (select count(*)::int from public.admission_test_candidate where sitting_id = :'sitting_a_id'::uuid and cancelled_at is null),
  1,
  'sitting A now has only candidate two active — the freed seat is available again'
);

-- The freed seat in sitting A can now take candidate three.
select public.fn_allocate_test_seat(:'sitting_a_id'::uuid, :'app3_id'::uuid) as seat3 \gset
select ok(:'seat3'::int is not null, 'a seat freed by reallocation can be filled by a new candidate');

-- ── AC3: the roll-slip payload lists every active candidate in
--    contiguous seat order ──────────────────────────────────────────

select (public.fn_build_roll_slip_payload(:'sitting_a_id'::uuid)) as payload_a \gset
select is(
  jsonb_array_length((:'payload_a')::jsonb -> 'candidates'),
  2,
  'the roll slip payload lists exactly the 2 active candidates (the cancelled one is excluded)'
);
select is(
  ((:'payload_a')::jsonb -> 'candidates' -> 0 ->> 'seat_no')::int, 2,
  'AC: seats render in ascending order — candidate two (seat 2) first'
);
select is(
  ((:'payload_a')::jsonb -> 'candidates' -> 1 ->> 'child_name')::text, 'Candidate Three',
  'candidate three, backfilled into the freed seat, appears on the roster'
);

-- ── validation and tenant isolation ─────────────────────────────────

select throws_ok(
  format('select public.create_test_sitting(%L, %L, %L, now(), 0)', :'campus_id', :'session_id', :'class1_id'),
  'CAPACITY_MUST_BE_POSITIVE',
  'a sitting with zero capacity is rejected'
);

reset role;
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@sittingotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select throws_ok(
  format('select public.fn_allocate_test_seat(%L, %L)', :'sitting_a_id', :'app3_id'),
  'SITTING_NOT_FOUND',
  'fn_allocate_test_seat refuses a foreign-tenant sitting id'
);
select is(
  (select count(*)::int from public.admission_test_sitting),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero sittings via RLS'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.create_test_sitting(%L, %L, %L, now(), 30)', :'campus_id', :'session_id', :'class1_id'),
  'FORBIDDEN',
  'a role with no admissions access cannot schedule a test sitting'
);

select * from finish();
rollback;
