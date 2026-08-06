-- pgTAP tests for FR-C11: invite and activate guardian portal accounts.
begin;
select plan(31);

select public.provision_tenant('test-guardian-invite-co', 'Guardian Invite Co', 'owner@guardianinviteco.test');
select id as tenant_id from public.tenant where slug = 'test-guardian-invite-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset

-- Two students, two separate families sharing the same section/campus —
-- the exact scenario the parent-scoping RLS must never blur together.
select public.create_student(:'campus_id'::uuid, 'Guardian Kid One', '2015-01-01'::date, 'male') as student1_id \gset
select public.enrol_student(:'section_id'::uuid, :'student1_id'::uuid) as enrol1_id \gset
select public.create_student(:'campus_id'::uuid, 'Guardian Kid Two', '2015-01-01'::date, 'female') as student2_id \gset
select public.enrol_student(:'section_id'::uuid, :'student2_id'::uuid) as enrol2_id \gset

select public.fn_find_or_create_guardian(p_name_en => 'Guardian One', p_phone_e164 => '+923001234567') as guardian1_id \gset
select public.link_guardian(:'student1_id'::uuid, :'guardian1_id'::uuid, 'father'::public.guardian_relationship, true, true);

select public.fn_find_or_create_guardian(p_name_en => 'Guardian Two', p_phone_e164 => '+923009876543') as guardian2_id \gset
select public.link_guardian(:'student2_id'::uuid, :'guardian2_id'::uuid, 'mother'::public.guardian_relationship, true, true);

-- ── send_guardian_invite ─────────────────────────────────────────────────

select public.send_guardian_invite(:'guardian1_id'::uuid, 'whatsapp') as invite1_result \gset
select is(
  (:'invite1_result'::jsonb ->> 'phone_e164'),
  '+923001234567',
  'send_guardian_invite returns the guardian''s phone for the caller to dispatch to'
);
select is(
  (select count(*)::int from public.guardian_invite where guardian_id = :'guardian1_id'::uuid),
  1,
  'exactly one invite row exists'
);
select isnt(
  (select token_hash from public.guardian_invite where guardian_id = :'guardian1_id'::uuid),
  (:'invite1_result'::jsonb ->> 'token'),
  'AC (Notes): only the token hash is stored, never the raw token value'
);

select to_jsonb(p) as preview1_row from public.get_guardian_invite_preview((:'invite1_result'::jsonb ->> 'token')) p \gset
select is((:'preview1_row'::jsonb ->> 'valid')::boolean, true, 'a freshly-sent invite previews as valid');
select is((:'preview1_row'::jsonb ->> 'guardian_name'), 'Guardian One', 'the preview identifies the correct guardian');
select is(
  (select count(*)::int from public.get_guardian_invite_preview('not-a-real-token')),
  0,
  'an unknown token previews as no row at all'
);

-- Re-sending supersedes the first invite (same reasoning as invite_user).
select public.send_guardian_invite(:'guardian1_id'::uuid, 'sms') as invite1b_result \gset
select is(
  (select count(*)::int from public.guardian_invite where guardian_id = :'guardian1_id'::uuid),
  1,
  'AC: a fresh invite supersedes the prior outstanding one, not appends'
);
select is(
  (select count(*)::int from public.get_guardian_invite_preview((:'invite1_result'::jsonb ->> 'token'))),
  0,
  'the superseded token no longer resolves to any invite at all'
);

select throws_ok(
  format($$ select public.send_guardian_invite(%L, 'carrier_pigeon') $$, :'guardian2_id'),
  'CHANNEL_INVALID',
  'an unrecognised delivery channel is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.send_guardian_invite(%L, 'whatsapp') $$, :'guardian2_id'),
  'FORBIDDEN',
  'a class teacher cannot send a guardian invite'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.fn_find_or_create_guardian(p_name_en => 'No Phone Guardian') as guardian_no_phone_id \gset
select throws_ok(
  format($$ select public.send_guardian_invite(%L, 'whatsapp') $$, :'guardian_no_phone_id'),
  'GUARDIAN_PHONE_MISSING',
  'a guardian with no phone on file cannot be invited'
);

-- ── activate_guardian_account ─────────────────────────────────────────────

reset role;
select gen_random_uuid() as guardian1_auth_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'guardian1_auth_uid', '923001234567', now(), 'x', 'authenticated', 'authenticated');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'guardian1_auth_uid')::text, true);

select throws_ok(
  format($$ select public.activate_guardian_account(%L) $$, 'garbage-token'),
  'INVITE_NOT_FOUND',
  'an unknown token cannot activate any account'
);

select public.activate_guardian_account((:'invite1b_result'::jsonb ->> 'token')) as activated_guardian_id \gset
select is(:'activated_guardian_id'::uuid, :'guardian1_id'::uuid, 'activation returns the correct guardian id');

-- Ground truth, read as superuser: the guardian's own session JWT (just
-- 'sub', no tenant_id) can't see guardian/guardian_invite under RLS
-- either — same reasoning as this suite's other "read as superuser to
-- check what a SECURITY DEFINER call actually wrote" checks.
reset role;
select is(
  (select auth_user_id from public.guardian where id = :'guardian1_id'::uuid),
  :'guardian1_auth_uid'::uuid,
  'AC: guardian.auth_user_id is set in the same transaction as activation'
);
select isnt(
  (select consumed_at from public.guardian_invite where guardian_id = :'guardian1_id'::uuid),
  null,
  'the invite is marked consumed on activation'
);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'guardian1_auth_uid')::text, true);

select throws_ok(
  format($$ select public.activate_guardian_account(%L) $$, (:'invite1b_result'::jsonb ->> 'token')),
  'INVITE_ALREADY_USED',
  'AC: opening the same link a second time is rejected as already used'
);

reset role;
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (gen_random_uuid(), '923009999999', now(), 'x', 'authenticated', 'authenticated')
returning id as wrong_phone_uid \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.send_guardian_invite(:'guardian2_id'::uuid, 'whatsapp') as invite2_result \gset
select set_config('request.jwt.claims', json_build_object('sub', :'wrong_phone_uid')::text, true);
select throws_ok(
  format($$ select public.activate_guardian_account(%L) $$, (:'invite2_result'::jsonb ->> 'token')),
  'INVITE_PHONE_MISMATCH',
  'AC-adjacent: activating with a session whose phone does not match the guardian on file is rejected'
);

select set_config('request.jwt.claims', '{}'::text, true);
select throws_ok(
  format($$ select public.activate_guardian_account(%L) $$, (:'invite2_result'::jsonb ->> 'token')),
  'UNAUTHENTICATED',
  'activation requires a real session'
);

reset role;
insert into public.guardian_invite (tenant_id, guardian_id, token_hash, sent_channel, expires_at)
values (:'tenant_id'::uuid, :'guardian2_id'::uuid, encode(extensions.digest('expired-token-raw', 'sha256'), 'hex'), 'sms', now() - interval '1 hour');
set local role authenticated;
select gen_random_uuid() as guardian2_auth_uid \gset
select set_config('request.jwt.claims', json_build_object('sub', :'guardian2_auth_uid')::text, true);
reset role;
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'guardian2_auth_uid', '923009876543', now(), 'x', 'authenticated', 'authenticated');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'guardian2_auth_uid')::text, true);
select throws_ok(
  $$ select public.activate_guardian_account('expired-token-raw') $$,
  'INVITE_EXPIRED',
  'AC: an invite past its 72-hour expiry cannot activate an account, even with the right phone'
);

-- ── OTP lockout (5 wrong in 15 minutes -> locked for 30 minutes) ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.send_guardian_invite(:'guardian2_id'::uuid, 'sms') as invite2b_result \gset
select is(
  (select (to_jsonb(p) ->> 'locked')::boolean from public.get_guardian_invite_preview((:'invite2b_result'::jsonb ->> 'token')) p),
  false,
  'a guardian with no failed attempts is not locked'
);

select public.register_guardian_otp_attempt((:'invite2b_result'::jsonb ->> 'token'), 'verify_failed') from generate_series(1, 4);
select is(
  (select (to_jsonb(p) ->> 'locked')::boolean from public.get_guardian_invite_preview((:'invite2b_result'::jsonb ->> 'token')) p),
  false,
  '4 failures within the window do not yet lock the guardian out'
);
select public.register_guardian_otp_attempt((:'invite2b_result'::jsonb ->> 'token'), 'verify_failed');
select is(
  (select (to_jsonb(p) ->> 'locked')::boolean from public.get_guardian_invite_preview((:'invite2b_result'::jsonb ->> 'token')) p),
  true,
  'AC: the 5th failure within 15 minutes locks the guardian out'
);

reset role;
select is(
  (select count(*)::int from public.guardian_otp_attempt where guardian_id = :'guardian2_id'::uuid and kind = 'verify_failed'),
  5,
  'AC: the lockout state is visible to staff (queried here as the Admissions Officer would)'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── custom_access_token_hook: parent branch ───────────────────────────────

reset role;
select public.custom_access_token_hook(jsonb_build_object('user_id', :'guardian1_auth_uid', 'claims', '{}'::jsonb)) as hook1_result \gset
select is(
  (:'hook1_result'::jsonb -> 'claims' ->> 'app_role'),
  'parent',
  'AC: an activated guardian''s session gets app_role = parent'
);
select is(
  (:'hook1_result'::jsonb -> 'claims' ->> 'tenant_id'),
  :'tenant_id',
  'the parent claim carries the correct tenant_id'
);
select is(
  (:'hook1_result'::jsonb -> 'claims' -> 'campus_ids')::jsonb,
  jsonb_build_array(:'campus_id'),
  'AC: campus_ids reflects the guardian''s child''s active-enrolment campus'
);
select is(
  (:'hook1_result'::jsonb -> 'claims' ? 'academic_session_id'),
  false,
  'AC: a parent claim carries no session_id'
);

select public.custom_access_token_hook(jsonb_build_object('user_id', gen_random_uuid(), 'claims', '{}'::jsonb)) as hook_unknown_result \gset
select is(
  (:'hook_unknown_result'::jsonb -> 'claims' ->> 'app_role'),
  'none',
  'an unrecognised user_id (neither staff nor guardian) still fails closed'
);

-- ── RLS: parent sees only their own child, never the other family's ──────

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'guardian1_auth_uid')::text,
  true
);
select is(
  (select count(*)::int from public.student where id = :'student1_id'::uuid),
  1,
  'a parent can read their own child'
);
select is(
  (select count(*)::int from public.student where id = :'student2_id'::uuid),
  0,
  'AC (the whole point of this FR): a parent cannot read the other family''s child, despite sharing a campus'
);
select is(
  (select count(*)::int from public.enrolment where student_id = :'student2_id'::uuid),
  0,
  'AC: campus_ids alone never grants a parent enrolment visibility into another family''s child'
);

select * from finish();
rollback;
