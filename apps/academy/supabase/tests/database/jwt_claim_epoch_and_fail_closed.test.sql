-- pgTAP tests for FR-A13: custom JWT claim issuance — epoch-based
-- staleness rejection and fail-closed hook error handling.
--
-- custom_access_token_hook is granted only to supabase_auth_admin and
-- revoked from authenticated/anon/public (foundation.sql), so it is called
-- directly here while still running as the test's own superuser role,
-- before any `set local role authenticated` — exactly like foundation.
-- test.sql captures tenant ids "as superuser BEFORE switching role".
begin;
select plan(18);

select public.provision_tenant('test-epoch-co', 'Epoch Co', 'owner@epochco.test');
select id as tenant_id from public.tenant where slug = 'test-epoch-co' \gset
select id as campus1_id from public.campus where tenant_id = :'tenant_id' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus North', 'NORTH') returning id as campus2_id \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus3_id \gset

select gen_random_uuid() as staff_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'staff_user_id', 'staff@epochco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'staff_user_id', :'tenant_id', 'subject_teacher', 'Test Staff');

insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus1_id');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus2_id');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus3_id');

-- Baseline cv AFTER setup (the 3 user_campus inserts above each bump the
-- epoch themselves, same as any other campus-assignment change would) —
-- every assertion below is relative to this, not a hardcoded literal, so
-- it doesn't hard-code how many bumps happened during fixture setup.
select claims_version as baseline_cv from public.app_user where user_id = :'staff_user_id' \gset

-- ── AC1: campus_ids is a 3-element array, tenant_id matches the default
--    (only) membership ────────────────────────────────────────────────────

select public.custom_access_token_hook(jsonb_build_object('user_id', :'staff_user_id', 'claims', '{}'::jsonb)) as hook1 \gset

select is(
  ((:'hook1')::jsonb -> 'claims' ->> 'tenant_id')::uuid, :'tenant_id'::uuid,
  'AC1: issued token''s tenant_id matches the user''s membership'
);
select is(
  jsonb_array_length((:'hook1')::jsonb -> 'claims' -> 'campus_ids'), 3,
  'AC1: issued token''s campus_ids is a 3-element array for a user with 3 campuses'
);
select is(
  ((:'hook1')::jsonb -> 'claims' ->> 'cv')::int, :'baseline_cv'::int,
  'the issued token''s cv matches the live claims_version'
);

-- ── epoch bump: a role change increments claims_version, and the new
--    token minted after it carries the bumped cv ──────────────────────────

update public.app_user set app_role = 'principal' where user_id = :'staff_user_id';

select is(
  (select claims_version from public.app_user where user_id = :'staff_user_id'),
  :'baseline_cv'::int + 1,
  'changing app_role bumps app_user.claims_version (the epoch)'
);

select public.custom_access_token_hook(jsonb_build_object('user_id', :'staff_user_id', 'claims', '{}'::jsonb)) as hook2 \gset

select is(
  (:'hook2')::jsonb -> 'claims' ->> 'app_role', 'principal',
  'AC2: a token minted after the role change carries the new role'
);
select is(
  ((:'hook2')::jsonb -> 'claims' ->> 'cv')::int, :'baseline_cv'::int + 1,
  'AC2: a token minted after the role change carries the bumped cv'
);

-- A no-op update (same values) must not bump the epoch again.
update public.app_user set app_role = 'principal' where user_id = :'staff_user_id';
select is(
  (select claims_version from public.app_user where user_id = :'staff_user_id'),
  :'baseline_cv'::int + 1,
  'a no-op update (unchanged app_role/status) does not bump claims_version'
);

-- ── epoch bump on campus reassignment ───────────────────────────────────

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus East', 'EAST') returning id as campus4_id \gset
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'staff_user_id', :'tenant_id', :'campus4_id');

select is(
  (select claims_version from public.app_user where user_id = :'staff_user_id'),
  :'baseline_cv'::int + 2,
  'adding a campus assignment (user_campus insert) also bumps claims_version'
);

-- ── AC2: the OLD (stale-cv) token is rejected with TOKEN_EPOCH_STALE; a
--    fresh-cv token still works ─────────────────────────────────────────

set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'sub', :'staff_user_id', 'cv', :'baseline_cv'::int + 1)::text,
  true
);
select throws_ok(
  'select app.auth_tenant_id()',
  'TOKEN_EPOCH_STALE',
  'AC2: a token carrying a stale cv (one bump behind) is rejected once the live epoch has moved on'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'sub', :'staff_user_id', 'cv', :'baseline_cv'::int + 2)::text,
  true
);
select is(
  app.auth_tenant_id(), :'tenant_id'::uuid,
  'AC2: a token carrying the current cv is accepted'
);

-- ── regression: a JWT with no cv claim at all (every pre-existing pgTAP
--    test in this repo, plus service_role/legacy tokens) is never rejected
--    — the epoch check is additive, not a behavior change for callers that
--    predate it ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'sub', :'staff_user_id')::text,
  true
);
select lives_ok(
  'select app.auth_tenant_id()',
  'a JWT with no cv claim at all is never treated as stale (back-compat with every pre-existing synthetic JWT)'
);

-- A JWT with a sub that matches no app_user row (e.g. a guardian/parent
-- token) is likewise never treated as stale by this check.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'sub', gen_random_uuid(), 'cv', 1)::text,
  true
);
select lives_ok(
  'select app.auth_tenant_id()',
  'a cv claim for a sub with no app_user row (e.g. a guardian token) is never treated as stale'
);

reset role;

-- ── AC4: the hook fails closed with AUTH_CLAIMS_UNAVAILABLE when it hits
--    a genuine internal fault, instead of returning a valid null-tenant
--    token ──────────────────────────────────────────────────────────────

select public.custom_access_token_hook(jsonb_build_object('user_id', 'not-a-uuid', 'claims', '{}'::jsonb)) as hook_err \gset

select is(
  (:'hook_err')::jsonb -> 'error' ->> 'message', 'AUTH_CLAIMS_UNAVAILABLE',
  'AC4: a hook fault (malformed user_id) fails closed with AUTH_CLAIMS_UNAVAILABLE'
);
select is(
  ((:'hook_err')::jsonb -> 'error' ->> 'http_code')::int, 500,
  'AC4: the fail-closed error carries an http_code'
);
select ok(
  not ((:'hook_err')::jsonb ? 'claims'),
  'AC4: the fail-closed response carries no claims object at all — no token is issued'
);

-- ── regression: the pre-existing "authenticated but not a member of
--    anything" branch is unchanged by the exception handler — it still
--    issues a valid (RLS-denying) null-tenant token, not an error ────────

select public.custom_access_token_hook(jsonb_build_object('user_id', gen_random_uuid(), 'claims', '{}'::jsonb)) as hook_none \gset

select ok(
  not ((:'hook_none')::jsonb ? 'error'),
  'regression: a genuine "no membership" user still gets a normal (non-error) token'
);
select ok(
  (:'hook_none')::jsonb -> 'claims' -> 'tenant_id' = 'null'::jsonb,
  'regression: a "no membership" token still carries tenant_id null (fail-closed-by-RLS, not by hook error)'
);
select is(
  (:'hook_none')::jsonb -> 'claims' ->> 'app_role', 'none',
  'regression: a "no membership" token still carries app_role none'
);

select * from finish();
rollback;
