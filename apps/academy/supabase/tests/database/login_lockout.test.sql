-- pgTAP tests for FR-A09's lockout mechanism: register_login_attempt /
-- is_login_locked. Runs as anon, matching how the real login flow calls
-- these (pre-authentication).
begin;
select plan(8);

set local role anon;

select is(
  public.is_login_locked('fresh@lockout.test'),
  false,
  'an identifier with no attempts at all is not locked'
);

-- 9 failures: not yet locked.
select public.register_login_attempt('nine-fails@lockout.test', false) from generate_series(1, 9);
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  false,
  '9 consecutive failures does not lock the account'
);

-- 10th failure: now locked.
select public.register_login_attempt('nine-fails@lockout.test', false);
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  true,
  'the 10th consecutive failure locks the account'
);

-- An 11th failed attempt while locked does not "unlock" or otherwise error.
select public.register_login_attempt('nine-fails@lockout.test', false);
select is(
  public.is_login_locked('nine-fails@lockout.test'),
  true,
  'still locked after an 11th failure — the lock is anchored to the 10th, not extended'
);

-- A success resets the counter entirely.
select public.register_login_attempt('resets-on-success@lockout.test', false) from generate_series(1, 9);
select public.register_login_attempt('resets-on-success@lockout.test', true);
select is(
  public.is_login_locked('resets-on-success@lockout.test'),
  false,
  'a successful login resets the consecutive-failure count, even after 9 prior failures'
);
select public.register_login_attempt('resets-on-success@lockout.test', false) from generate_series(1, 9);
select is(
  public.is_login_locked('resets-on-success@lockout.test'),
  false,
  '9 MORE failures after the reset (18 total, but only 9 consecutive since the success) still does not lock'
);

-- Auto-unlock after 15 minutes: simulate by backdating the failures. login_attempt
-- has no UPDATE policy for anon/authenticated (by design — it's an internal
-- security log), so this backdate has to run as the superuser.
select public.register_login_attempt('expires@lockout.test', false) from generate_series(1, 10);
reset role;
update public.login_attempt set created_at = now() - interval '20 minutes' where identifier = 'expires@lockout.test';
set local role anon;
select is(
  public.is_login_locked('expires@lockout.test'),
  false,
  'a 10th failure older than 15 minutes has auto-unlocked'
);

-- lower() normalization: the same address in a different case is one identifier.
select public.register_login_attempt('CaseTest@Lockout.test', false) from generate_series(1, 10);
select is(
  public.is_login_locked('casetest@lockout.test'),
  true,
  'lockout is case-insensitive on the email identifier'
);

select * from finish();
rollback;
