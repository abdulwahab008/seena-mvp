-- Password-reset request ledger.
--
-- WHY THIS EXISTS AT ALL: GoTrue deletes the auth.one_time_tokens row the
-- moment a recovery token is verified, and returns the *same* error
-- (403 otp_expired, "Email link is invalid or has expired") for an expired
-- token, an already-used token, and pure garbage. There is therefore no way
-- to tell a user "this link has already been used" rather than the useless
-- "invalid or expired" without keeping our own record of what we issued.
--
-- This ledger is for MESSAGING AND RATE LIMITING ONLY. It is never the
-- authority on whether a reset may proceed — that remains
-- auth.verifyOtp(), which is checked on every submit regardless of what
-- classify_password_reset_token() said. A forged row here grants nothing.
--
-- It also closes a real hole: reset mail goes out through Resend, which
-- bypasses Supabase's own [auth.rate_limit] email_sent cap entirely, so
-- without is_password_reset_throttled() /forgot-password is an open
-- mail-bombing relay pointed at any address an attacker chooses.

create table public.password_reset_request (
  id          uuid primary key default gen_random_uuid(),
  email       citext not null,
  token_hash  text not null,
  created_at  timestamptz not null default now(),
  consumed_at timestamptz
);

create unique index password_reset_request_token_hash_uniq
  on public.password_reset_request (token_hash);
create index password_reset_request_email_idx
  on public.password_reset_request (email, created_at desc);

-- No RLS policies on purpose: an internal security log, reachable only via
-- the SECURITY DEFINER functions below. RLS enabled with zero policies =
-- default deny for everyone, including authenticated users.
alter table public.password_reset_request enable row level security;

-- Records a reset link we just minted. Service-role only: the caller must
-- have already proven, server-side, that it really issued this token.
create or replace function public.register_password_reset(p_email text, p_token_hash text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.password_reset_request (email, token_hash)
  values (lower(p_email), p_token_hash)
  on conflict (token_hash) do nothing;
$$;

revoke execute on function public.register_password_reset(text, text) from public, anon, authenticated;
grant execute on function public.register_password_reset(text, text) to service_role;

-- Classifies a token for display purposes. Callable by anon because the
-- reset page is reached with no session.
--
-- No enumeration concern: the argument IS the secret. Anyone able to call
-- this with a real token_hash already holds everything needed to complete
-- the reset, so confirming "this one was already used" tells them nothing
-- they could not learn by simply submitting the form.
--
-- The 1 hour window mirrors auth.otp_expiry in supabase/config.toml and the
-- "expires in 1 hour" line in lib/email/templates.ts. If that config
-- changes, change it here too or the message will contradict GoTrue.
create or replace function public.classify_password_reset_token(p_token_hash text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select case
               when r.consumed_at is not null then 'used'
               when r.created_at <= now() - interval '1 hour' then 'expired'
               else 'valid'
             end
        from public.password_reset_request r
       where r.token_hash = p_token_hash
    ),
    'unknown'
  );
$$;

revoke execute on function public.classify_password_reset_token(text) from public;
grant execute on function public.classify_password_reset_token(text) to anon, authenticated;

-- Marks a token spent. Service-role only, and called only after
-- verifyOtp() + updateUser() have both actually succeeded.
create or replace function public.consume_password_reset(p_token_hash text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.password_reset_request
     set consumed_at = now()
   where token_hash = p_token_hash
     and consumed_at is null;
$$;

revoke execute on function public.consume_password_reset(text) from public, anon, authenticated;
grant execute on function public.consume_password_reset(text) to service_role;

-- Caps reset mail at 3 per address per 15 minutes. Service-role only: it is
-- consulted before sending, from the same trusted action that sends.
create or replace function public.is_password_reset_throttled(p_email text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select count(*) >= 3
    from public.password_reset_request
   where email = lower(p_email)
     and created_at > now() - interval '15 minutes';
$$;

revoke execute on function public.is_password_reset_throttled(text) from public, anon, authenticated;
grant execute on function public.is_password_reset_throttled(text) to service_role;
