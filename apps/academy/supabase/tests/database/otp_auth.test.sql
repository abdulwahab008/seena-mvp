-- pgTAP tests for FR-A08's OTP rate-limit/lockout gate. The actual code
-- generation, expiry and delivery are Supabase Auth's own (native phone-OTP,
-- via [auth.sms.test_otp] in local dev) and aren't exercised here — see
-- e2e/otp-login.spec.ts for the end-to-end flow through that.
begin;
select plan(13);

set local role anon;

-- normalize_pk_phone: all four input forms resolve to the same E.164 value.
select is(public.normalize_pk_phone('+923001234567'), '+923001234567', 'already-E.164 form passes through');
select is(public.normalize_pk_phone('0300-1234567'), '+923001234567', 'hyphens and spaces (0300-1234567, +92 300 1234567 style) are stripped before matching');
select is(public.normalize_pk_phone('00923001234567'), '+923001234567', '0092-prefixed form normalizes');
select is(public.normalize_pk_phone('923001234567'), '+923001234567', '92-prefixed form normalizes');
select is(public.normalize_pk_phone('03001234567'), '+923001234567', '0-prefixed local form normalizes');
select is(public.normalize_pk_phone('not-a-phone'), null, 'garbage input normalizes to null');

select throws_ok(
  $$ select public.issue_otp('not-a-phone') $$,
  'PHONE_INVALID',
  'issue_otp rejects an unnormalizable phone'
);

select is(
  (public.issue_otp('+923009999001') ->> 'phone_e164'),
  '+923009999001',
  'issue_otp returns the normalized phone on success'
);

-- 5 more issuances (6 total) is the rate limit boundary.
select public.issue_otp('+923009999002') from generate_series(1, 5);
select lives_ok(
  $$ select public.issue_otp('+923009999002') $$,
  'the 6th issuance within an hour still succeeds (boundary, not yet over)'
);
select throws_ok(
  $$ select public.issue_otp('+923009999002') $$,
  'OTP_RATE_LIMITED',
  'the 7th issuance within an hour is rate-limited'
);

-- Lockout: fresh phone is not locked.
select is(public.is_otp_locked('+923009999003'), false, 'a phone with no attempts at all is not locked');

-- 4 wrong verifications after an issuance: not yet locked.
-- register_otp_attempt is service_role-only (an anon-callable writer let
-- anyone forge an 'issued' row and reset the strike counter) — the
-- superuser test role stands in for it, same as elsewhere in this suite.
select public.issue_otp('+923009999004');
reset role;
select public.register_otp_attempt('+923009999004', 'verify_failed') from generate_series(1, 4);
set local role anon;
select is(public.is_otp_locked('+923009999004'), false, '4 wrong verifications does not lock the code');

-- 5th wrong verification: locked.
reset role;
select public.register_otp_attempt('+923009999004', 'verify_failed');
set local role anon;
select is(public.is_otp_locked('+923009999004'), true, 'the 5th wrong verification locks the code');

select * from finish();
rollback;
