-- pgTAP tests for the Module A independent-review fixes
-- (20260731240000_module_a_review_fixes.sql).
begin;
select plan(5);

-- ── fix #1: register_login_attempt()/register_otp_attempt() can no
--    longer be called directly by anon or authenticated — an attacker
--    could otherwise forge a fake success/issued row and disarm both
--    lockout mechanisms without ever logging in ──────────────────────

set local role anon;
select throws_ok(
  $$ select public.register_login_attempt('victim@lockout.test', true) $$,
  'permission denied for function register_login_attempt',
  'an unauthenticated caller can no longer forge a fake login success to erase a victim''s failure history'
);
select throws_ok(
  $$ select public.register_otp_attempt('+923001112222', 'issued') $$,
  'permission denied for function register_otp_attempt',
  'an unauthenticated caller can no longer forge a fake OTP issuance to reset the 5-strikes verify counter'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', gen_random_uuid(), 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);
select throws_ok(
  $$ select public.register_login_attempt('victim@lockout.test', true) $$,
  'permission denied for function register_login_attempt',
  'a signed-in user of any role is likewise refused — this is a service_role-only write, not a role-gated one'
);
reset role;

-- ── fix #2: is_login_locked() is a live sliding-window count, not a
--    fixed historical anchor — a persistent attacker who keeps failing
--    past the original 15-minute mark stays locked out, instead of the
--    account silently reopening once that one specific old row ages out ─

select public.register_login_attempt('persistent-attacker@lockout.test', false) from generate_series(1, 10);
update public.login_attempt set created_at = now() - interval '20 minutes' where identifier = 'persistent-attacker@lockout.test';
-- 10 more, fresh: under the old fixed-anchor bug, the anchor was the
-- 10th-oldest failure (one of the 10 just backdated), so this scenario
-- used to report unlocked despite 10 very recent failures existing.
select public.register_login_attempt('persistent-attacker@lockout.test', false) from generate_series(1, 10);
set local role anon;
select is(
  public.is_login_locked('persistent-attacker@lockout.test'),
  true,
  'a persistent attacker with 10 failures inside the last 15 minutes stays locked, even though an earlier batch of 10 has aged out'
);
reset role;

-- The account still auto-unlocks once ALL failures fall outside the window.
select public.register_login_attempt('gives-up-attacker@lockout.test', false) from generate_series(1, 15);
update public.login_attempt set created_at = now() - interval '20 minutes' where identifier = 'gives-up-attacker@lockout.test';
set local role anon;
select is(
  public.is_login_locked('gives-up-attacker@lockout.test'),
  false,
  'once every failure (even 15 of them) has aged past 15 minutes with no new ones, the account is unlocked again'
);
reset role;

select * from finish();
rollback;
