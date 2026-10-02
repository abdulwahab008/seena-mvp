-- FR-A09 (password login hardening), lockout portion. Password minimum
-- length is set via supabase/config.toml's auth.minimum_password_length,
-- not here (that's Supabase Auth's own gate, not something this schema
-- can enforce).
--
-- Scope note: FR-A09 also asks for a 60-minute idle-session timeout for
-- financial/results roles specifically. Supabase Auth's own session-timeout
-- config (auth.sessions.inactivity_timeout) is tenant-global, not per-role,
-- so a *per-role* idle timeout needs its own last-activity-tracking
-- mechanism in middleware — a genuinely separate piece of work from
-- lockout. Deferred; lockout (the higher-severity gap — it stops a brute
-- force, not just an inconvenience) ships now.

create table public.login_attempt (
  id         uuid primary key default gen_random_uuid(),
  identifier text not null,
  succeeded  boolean not null,
  created_at timestamptz not null default now()
);

create index login_attempt_identifier_idx on public.login_attempt (identifier, created_at desc);

-- No RLS policies on purpose: this is an internal security log, reachable
-- only through the two SECURITY DEFINER functions below, never by direct
-- table access (RLS enabled with zero policies = default deny for everyone,
-- including authenticated users reading their own attempts).
alter table public.login_attempt enable row level security;

create or replace function public.register_login_attempt(p_identifier text, p_succeeded boolean)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.login_attempt (identifier, succeeded) values (lower(p_identifier), p_succeeded);
$$;

-- Callable by anon: an attempt is registered on every login POST, most of
-- which happen before the caller has a session.
revoke execute on function public.register_login_attempt(text, boolean) from public;
grant execute on function public.register_login_attempt(text, boolean) to anon, authenticated;

create or replace function public.is_login_locked(p_identifier text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with since_last_success as (
    select created_at
      from public.login_attempt
     where identifier = lower(p_identifier)
       and not succeeded
       and created_at > coalesce(
             (select max(created_at) from public.login_attempt
               where identifier = lower(p_identifier) and succeeded),
             '-infinity'::timestamptz
           )
     order by created_at asc
  ),
  tenth_failure as (
    select created_at from since_last_success offset 9 limit 1
  )
  select exists (select 1 from tenth_failure where created_at > now() - interval '15 minutes');
$$;

revoke execute on function public.is_login_locked(text) from public;
grant execute on function public.is_login_locked(text) to anon, authenticated;
