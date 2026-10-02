-- Module A (Foundation & Auth) hardening — two bugs found by an
-- independent second-pass review, the most severe found this session:
-- both of this module's brute-force defenses (password lockout and OTP
-- lockout) could be fully and permanently defeated.

-- ── 1. register_login_attempt()/register_otp_attempt() let an
--    unauthenticated caller forge the security log they feed ───────────
--
-- Both accepted a caller-asserted outcome (p_succeeded / p_kind) and
-- were GRANT EXECUTE ... TO anon — reachable directly via the public
-- anon key with no login at all, bypassing the Next.js server actions
-- entirely. `supabase.rpc('register_login_attempt', { p_identifier:
-- 'victim@school.test', p_succeeded: true })` writes a fake success row;
-- is_login_locked() anchors its window to the most recent succeeded row,
-- so this instantly erases every real prior failure and disarms lockout
-- — repeatable before/after every batch of password guesses for
-- unlimited-rate brute force. The identical trick against
-- register_otp_attempt(phone, 'issued') resets is_otp_locked()'s 5-
-- strikes counter (it only counts verify_failed rows since the most
-- recent 'issued' row) the same way.
--
-- Fixed by making both service_role-only: the app's server actions
-- (app/login/actions.ts, app/login/otp/actions.ts) now write these two
-- specific rows through the service-role client, which is never
-- exposed to a browser, instead of the anon-key client every other call
-- in those same actions correctly keeps using. is_login_locked()/
-- is_otp_locked()/issue_otp() stay anon-callable — they're read checks
-- or self-computed writes, not caller-assertable outcomes, and must
-- remain reachable pre-session.

revoke execute on function public.register_login_attempt(text, boolean) from anon, authenticated;
grant execute on function public.register_login_attempt(text, boolean) to service_role;

revoke execute on function public.register_otp_attempt(text, text) from anon, authenticated;
grant execute on function public.register_otp_attempt(text, text) to service_role;

-- ── 2. is_login_locked() anchored to a fixed historical row, so it
--    permanently self-disarmed 15 minutes after the FIRST lock ────────
--
-- The original query picked the fixed 10th-oldest failure since the
-- last success and checked only whether THAT ONE ROW was under 15
-- minutes old. Once 15 minutes pass since that specific row, the check
-- returns false forever for the rest of the streak, regardless of how
-- many more failures (11th, 12th, ... Nth) keep landing — the "10th"
-- position never moves without a real success. A patient attacker who
-- just waits out the initial 15-minute window (while still occasionally
-- failing) finds the account permanently unlocked from then on, even
-- while continuing to brute force it. is_otp_locked() never had this
-- flaw — it's already a live count, correctly re-evaluated every call.
-- Rewritten the same way: a live sliding-window count, not a fixed
-- anchor. Produces identical results to the old logic for every
-- previously-passing scenario in login_lockout.test.sql (verified) —
-- the only behavior change is that continued failures past the first
-- 15-minute mark correctly keep the account locked instead of
-- silently re-opening it.

create or replace function public.is_login_locked(p_identifier text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 10
    from public.login_attempt
   where identifier = lower(p_identifier)
     and not succeeded
     and created_at > now() - interval '15 minutes'
     and created_at > coalesce(
           (select max(created_at) from public.login_attempt
             where identifier = lower(p_identifier) and succeeded),
           '-infinity'::timestamptz
         );
$$;
