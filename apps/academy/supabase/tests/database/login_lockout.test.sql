-- pgTAP tests for FR-A09's lockout mechanism: register_login_attempt /
-- is_login_locked. is_login_locked runs as anon, matching how the real
-- login flow calls it (pre-authentication). register_login_attempt is
-- service_role-only (see the module_a_review_fixes migration — an
-- anon-callable writer let anyone forge the outcome and disarm lockout),
-- so the superuser test role is used for it instead, the same way it
-- stands in for service_role throughout this test suite.
begin;
select plan(8);

set local role anon;
select is(
  public.is_login_locked('fresh@lockout.test'),
  false,
  'an identifier with no attempts at all is not locked'
);
reset role;

-- 9 failures: not yet locked.
select public.register_login_attempt('nine-fails@lockout.test', false) from generate_series(1, 9);
set local role anon;
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  false,
  '9 consecutive failures does not lock the account'
);
reset role;

-- 10th failure: now locked.
select public.register_login_attempt('nine-fails@lockout.test', false);
set local role anon;
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  true,
  'the 10th consecutive failure locks the account'
);
reset role;

-- An 11th failed attempt while locked does not "unlock" or otherwise error.
select public.register_login_attempt('nine-fails@lockout.test', false);
set local role anon;
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  true,
  'still locked after an 11th failure'
);
reset role;

-- A success resets the counter entirely.
select public.register_login_attempt('resets-on-success@lockout.test', false) from generate_series(1, 9);
select public.register_login_attempt('resets-on-success@lockout.test', true);
set local role anon;
select is(
  public.is_login_locked('resets-on-success@lockout.test'),
  false,
  'a successful login resets the consecutive-failure count, even after 9 prior failures'
);
reset role;
select public.register_login_attempt('resets-on-success@lockout.test', false) from generate_series(1, 9);
set local role anon;
select is(
  public.is_login_locked('resets-on-success@lockout.test'),
  false,
  '9 MORE failures after the reset (18 total, but only 9 consecutive since the success) still does not lock'
);
reset role;

-- Auto-unlock after 15 minutes: simulate by backdating the failures.
select public.register_login_attempt('expires@lockout.test', false) from generate_series(1, 10);
update public.login_attempt set created_at = now() - interval '20 minutes' where identifier = 'expires@lockout.test';
set local role anon;
select is(
  public.is_login_locked('expires@lockout.test'),
  false,
  '10 failures all older than 15 minutes have aged out of the sliding window'
);
reset role;

-- lower() normalization: the same address in a different case is one identifier.
select public.register_login_attempt('CaseTest@Lockout.test', false) from generate_series(1, 10);
set local role anon;
select is(
  public.is_login_locked('casetest@lockout.test'),
  true,
  'lockout is case-insensitive on the email identifier'
);
reset role;

select * from finish();
rollback;
