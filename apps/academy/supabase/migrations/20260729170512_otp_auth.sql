-- FR-A08 (mobile OTP authentication), rate-limit/lockout portion. Actual
-- code generation, SMS/WhatsApp dispatch, and session minting are all
-- Supabase Auth's native phone-OTP mechanism (auth.signInWithOtp /
-- auth.verifyOtp, see app/login/otp/actions.ts) — this migration only adds
-- the extra gate the FR's acceptance criteria demand on top of that (Supabase
-- has its own generic rate limit, but no "5 wrong attempts burns the code"
-- lockout and no WhatsApp-fallback concept at all).
--
-- Scope cut: this authenticates an EXISTING app_user by phone (any role —
-- app_user.phone_e164 already existed for this from the foundation
-- migration). Self-serve parent signup via OTP is out of scope until Module
-- C/N (Guardians / Parent Portal) exist for a brand-new account to land in;
-- signInWithOtp is called with shouldCreateUser: false (see
-- app/login/otp/actions.ts) so it only ever signs in a phone that an admin
-- already put on an auth.users row. (auth.sms.enable_signup itself has to
-- be true — despite the name it's GoTrue's whole-provider switch, not a
-- signup-specific one; shouldCreateUser is the real per-call gate.)
--
-- Also out of scope: the 20-second SMS-delivery-failure -> WhatsApp fallback.
-- That needs a real aggregator's delivery-confirmation webhook to observe
-- "delivery failed" from — nothing to wire it to in local dev. The `channel`
-- column exists so that dispatch logic has somewhere to record which channel
-- was used once it exists.

create table public.otp_attempt (
  id         uuid primary key default gen_random_uuid(),
  -- Monotonic tiebreaker for "since the last issuance" in is_otp_locked
  -- below — created_at alone isn't safe for that: it's transaction_timestamp
  -- under the hood, so every row inserted within the same transaction (any
  -- test, and in principle rapid real calls too) shares one identical value.
  seq        bigserial not null,
  phone_e164 text not null,
  kind       text not null check (kind in ('issued', 'verify_failed', 'verify_succeeded')),
  channel    text not null default 'sms' check (channel in ('sms', 'whatsapp')),
  created_at timestamptz not null default now()
);

create index otp_attempt_phone_idx on public.otp_attempt (phone_e164, created_at desc);

-- No RLS policies on purpose, same reasoning as login_attempt: an internal
-- security log, reachable only through the SECURITY DEFINER functions below.
alter table public.otp_attempt enable row level security;

create or replace function public.normalize_pk_phone(p_phone text)
returns text
language plpgsql
immutable
as $$
declare
  -- Strips spaces/hyphens (0300-1234567, +92 300 1234567, ...) before
  -- pattern matching — FR-B01 explicitly wants both of those forms handled,
  -- not just the bare-digit forms FR-A08 originally covered.
  v_digits text := regexp_replace(p_phone, '[^0-9+]', '', 'g');
begin
  return case
    when v_digits ~ '^\+92\d{10}$' then v_digits
    when v_digits ~ '^0092\d{10}$' then '+92' || substring(v_digits from 5)
    when v_digits ~ '^92\d{10}$'   then '+' || v_digits
    when v_digits ~ '^0\d{10}$'    then '+92' || substring(v_digits from 2)
    else null
  end;
end;
$$;

revoke execute on function public.normalize_pk_phone(text) from public;
grant execute on function public.normalize_pk_phone(text) to anon, authenticated;

-- Issuance rate limit: 6 issued codes per phone per rolling hour.
create or replace function public.issue_otp(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text;
  v_count int;
begin
  v_phone := public.normalize_pk_phone(p_phone);
  if v_phone is null then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;

  select count(*) into v_count
    from public.otp_attempt
   where phone_e164 = v_phone
     and kind = 'issued'
     and created_at > now() - interval '1 hour';

  if v_count >= 6 then
    raise exception 'OTP_RATE_LIMITED' using errcode = '42901', detail = 'retry_after_seconds=3600';
  end if;

  insert into public.otp_attempt (phone_e164, kind) values (v_phone, 'issued');

  return jsonb_build_object('phone_e164', v_phone);
end;
$$;

revoke execute on function public.issue_otp(text) from public;
grant execute on function public.issue_otp(text) to anon, authenticated;

-- Lockout: 5 wrong verifications against the current code (i.e. since the
-- most recent issuance) burns it — the 6th attempt fails even if correct,
-- so the caller must check this BEFORE calling auth.verifyOtp, not after.
create or replace function public.is_otp_locked(p_phone text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with v as (select public.normalize_pk_phone(p_phone) as phone),
  last_issued as (
    select seq from public.otp_attempt, v
     where phone_e164 = v.phone and kind = 'issued'
     order by seq desc limit 1
  )
  select count(*) >= 5
    from public.otp_attempt, v
   where phone_e164 = v.phone
     and kind = 'verify_failed'
     and seq > coalesce((select seq from last_issued), -1);
$$;

revoke execute on function public.is_otp_locked(text) from public;
grant execute on function public.is_otp_locked(text) to anon, authenticated;

create or replace function public.register_otp_attempt(p_phone text, p_kind text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.otp_attempt (phone_e164, kind)
  values (public.normalize_pk_phone(p_phone), p_kind);
$$;

revoke execute on function public.register_otp_attempt(text, text) from public;
grant execute on function public.register_otp_attempt(text, text) to anon, authenticated;
