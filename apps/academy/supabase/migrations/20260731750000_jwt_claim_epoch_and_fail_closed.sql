-- FR-A13: custom JWT claim issuance — epoch-based staleness rejection and
-- fail-closed hook error handling.
--
-- What already existed before this migration (20260729135955_foundation.sql,
-- 20260729171840_role_catalogue.sql, 20260731560000_guardian_portal_invite.sql):
--   * custom_access_token_hook already stamps tenant_id, campus_ids, app_role,
--     academic_session_id, role_id and cv (= app_user.claims_version) into
--     every staff token, and tenant_id/campus_ids/app_role/cv into every
--     guardian ("parent") token. session_id is NOT stamped by the hook
--     because GoTrue already puts it on every access token as a first-class
--     claim (tied to the auth.sessions row) — there is nothing for this
--     hook to add there.
--   * app_user.claims_version already exists as the epoch column, and is
--     already read into the 'cv' claim on every issuance.
--   * role_catalogue.sql's own header explicitly deferred the rest of this
--     FR: "FR-A13's 'token rejected within 60s of a role change' live-
--     revocation guarantee is NOT implemented here ... until FR-A13's epoch
--     check ships." This migration is that epoch check.
--
-- What this migration adds:
--   1. app.tg_bump_claims_version(): BEFORE UPDATE OF app_role, status ON
--      app_user bumps claims_version whenever either changes — the "epoch
--      bump" (this schema's equivalent of the FR's suggested trg_bump_epoch
--      on user_membership; app_user IS the membership row here).
--   2. app.tg_bump_claims_version_on_campus_change(): AFTER INSERT/UPDATE/
--      DELETE ON user_campus bumps the owning app_user's claims_version too
--      — a campus reassignment must go stale exactly like a role change,
--      since campus_ids rides in the same token.
--   3. app.assert_claims_fresh(): SECURITY DEFINER, for the same reason
--      app.auth_guardian_student_ids() (guardian_portal_invite.sql) is —
--      reading app_user from inside an app.auth_*() helper that RLS
--      policies call would otherwise recurse into app_user's own RLS policy
--      and hit "stack depth limit exceeded". Compares the JWT's cv claim
--      against the live app_user.claims_version and raises
--      TOKEN_EPOCH_STALE on mismatch. No-ops (returns true) when the JWT
--      carries no cv claim, or auth.uid() has no app_user row: that covers
--      service_role, guardians (whose cv is pinned at issuance and not
--      contested by this check), and every pre-existing pgTAP test in this
--      repo, none of which set a cv claim on their synthetic JWTs — so this
--      is a strictly additive safety net, not a behavior change for
--      anything that predates it.
--   4. app.auth_tenant_id() now calls assert_claims_fresh() before
--      returning its value. tenant_id = app.auth_tenant_id() is the leading
--      conjunct of essentially every RLS policy already shipped in this
--      codebase, so this is the one place that gives every already-shipped
--      table live epoch enforcement without touching ~100 other migrations'
--      policies individually.
--   5. custom_access_token_hook wrapped in BEGIN/EXCEPTION: a genuine fault
--      while resolving claims (malformed event payload, a query error) now
--      returns the hook's own {"error": {"http_code", "message"}} shape
--      (the Auth Hooks error contract — see
--      https://supabase.com/docs/guides/auth/auth-hooks#error-handling)
--      with message 'AUTH_CLAIMS_UNAVAILABLE', instead of either leaking a
--      raw Postgres error or — worse — silently falling through to the
--      existing "no active membership" branch, which returns a *valid*
--      token with tenant_id null. That branch is deliberately left
--      untouched for the genuine "authenticated but not a member of
--      anything" case; the new handler only guards the distinct "something
--      broke while resolving claims" case FR-A13's AC4 asks for.
--
-- Not implemented — flagged, not silently skipped: AC3 ("a user belongs to
-- 2 tenants ... switches tenant in the UI"). public.app_user has user_id
-- (= auth.users.id) as its PRIMARY KEY with exactly one tenant_id column,
-- and foundation.sql's app_user_tenant_immutable trigger explicitly forbids
-- that column ever changing on a row; 20260731300000_module_b_review_
-- fixes.sql's own comment states the same design point verbatim
-- ("app_user.user_id is a single global id with exactly one tenant").
-- Multi-tenant membership per auth user does not exist anywhere in this
-- schema, and building it — a many-to-many membership table, a
-- tenant-switch RPC, a claim re-mint path, plus auditing every RLS policy
-- that currently trusts app_user.tenant_id as sole truth — is a schema-level
-- redesign, not an extension of what's here. Out of scope for this
-- migration; would conflict with, not extend, the existing model.

-- ── 1 & 2: epoch bump triggers ──────────────────────────────────────────

create or replace function app.tg_bump_claims_version()
returns trigger
language plpgsql
as $$
begin
  if new.app_role is distinct from old.app_role
     or new.status is distinct from old.status then
    new.claims_version := old.claims_version + 1;
  end if;
  return new;
end;
$$;

create trigger app_user_bump_claims_version
  before update of app_role, status on public.app_user
  for each row execute function app.tg_bump_claims_version();

create or replace function app.tg_bump_claims_version_on_campus_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := coalesce(new.user_id, old.user_id);
begin
  update public.app_user set claims_version = claims_version + 1 where user_id = v_user_id;
  return coalesce(new, old);
end;
$$;

create trigger user_campus_bump_claims_version
  after insert or update or delete on public.user_campus
  for each row execute function app.tg_bump_claims_version_on_campus_change();

-- ── 3 & 4: epoch staleness check, wired into the tenant-id fence ─────────

create or replace function app.assert_claims_fresh()
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_claim_cv int := nullif(app.jwt() ->> 'cv', '')::int;
  v_uid      uuid := (select auth.uid());
  v_live_cv  int;
begin
  if v_claim_cv is null or v_uid is null then
    return true;
  end if;

  select claims_version into v_live_cv from public.app_user where user_id = v_uid;
  if not found then
    return true;
  end if;

  if v_claim_cv <> v_live_cv then
    raise exception 'TOKEN_EPOCH_STALE' using errcode = '28000';
  end if;

  return true;
end;
$$;

revoke execute on function app.assert_claims_fresh() from public, anon;
grant execute on function app.assert_claims_fresh() to authenticated;

create or replace function app.auth_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(app.jwt() ->> 'tenant_id', '')::uuid
   where app.assert_claims_fresh();
$$;

-- ── 5: fail-closed hook error handling ───────────────────────────────────
-- Body below is byte-for-byte the existing hook (staff branch, guardian
-- branch, not-a-member branch) from guardian_portal_invite.sql, now wrapped
-- in begin/exception so an internal fault fails the login instead of either
-- leaking a raw error or silently issuing a null-tenant token.

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims  jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  u       record;
  gu      record;
begin
  select au.tenant_id,
         au.app_role::text as app_role,
         au.claims_version,
         coalesce(
           (select array_agg(uc.campus_id)
              from public.user_campus uc
             where uc.user_id = au.user_id and uc.is_active),
           '{}'::uuid[]
         ) as campus_ids,
         (select s.id
            from public.academic_session s
           where s.tenant_id = au.tenant_id and s.is_current
           limit 1) as academic_session_id,
         (select r.id
            from public.role r
           where r.tenant_id = au.tenant_id and r.code = au.app_role::text and r.deleted_at is null
           limit 1) as role_id
    into u
    from public.app_user au
   where au.user_id = (event ->> 'user_id')::uuid
     and au.status = 'active';

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',           u.tenant_id,
      'campus_ids',          to_jsonb(u.campus_ids),
      'app_role',            u.app_role,
      'academic_session_id', u.academic_session_id,
      'role_id',             u.role_id,
      'cv',                  u.claims_version
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  select g.tenant_id,
         coalesce(
           (select array_agg(distinct e.campus_id)
              from public.student_guardian sg
              join public.enrolment e on e.student_id = sg.student_id and e.status = 'active'
             where sg.guardian_id = g.id and sg.to_date is null),
           '{}'::uuid[]
         ) as campus_ids
    into gu
    from public.guardian g
   where g.auth_user_id = (event ->> 'user_id')::uuid;

  if found then
    claims := claims || jsonb_build_object(
      'tenant_id',  gu.tenant_id,
      'campus_ids', to_jsonb(gu.campus_ids),
      'app_role',   'parent',
      'cv',         1
    );
    return jsonb_set(event, '{claims}', claims);
  end if;

  -- Neither an active staff member nor an activated guardian: tenant_id =
  -- null makes every tenant-fence policy evaluate to NULL, which RLS
  -- treats as deny — same fail-closed shape as the original branch.
  return jsonb_set(event, '{claims}',
    claims || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
exception
  when others then
    -- FR-A13 AC4: a genuine fault while resolving claims must fail the
    -- login outright (no token issued), not fall through to the
    -- not-a-member branch above, which returns a *valid* (if useless)
    -- token. This is the Postgres Auth Hooks error-handling contract:
    -- GoTrue reads error.http_code/error.message off the hook's own return
    -- value rather than off an unhandled exception.
    return jsonb_build_object(
      'error', jsonb_build_object(
        'http_code', 500,
        'message', 'AUTH_CLAIMS_UNAVAILABLE'
      )
    );
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
