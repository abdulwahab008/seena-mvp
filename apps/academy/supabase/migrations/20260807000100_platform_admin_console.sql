-- Platform admin console: the people who run Seena itself, above every school.
--
-- Until now the only way to create a school was /admin/provision behind a
-- shared ADMIN_SETUP_TOKEN, and 'super_admin' is a role *inside* one tenant
-- (app_user.tenant_id is not null and immutable). A platform admin is neither:
-- it is an auth user listed in platform_admin, with no tenant membership.
--
-- The first platform admin is created by hand in the SQL editor:
--   insert into public.platform_admin (user_id)
--   select id from auth.users where email = 'you@example.com';
--
-- Suspending or closing a school now actually locks it:
--   * custom_access_token_hook strips tenant_id from any token whose tenant is
--     not 'active', so every tenant-fenced RLS policy denies (same shape as
--     the existing "no membership" branch).
--   * staff tokens already issued go stale at once: claims_version is bumped
--     for the tenant's app_users, and app.auth_tenant_id() rejects a stale cv
--     on the next query (20260731750000_jwt_claim_epoch_and_fail_closed.sql).
--   * parent and student tokens carry no contested cv, so they keep working
--     until they expire (at most the JWT lifetime, 1 hour by default) and are
--     then re-minted without a tenant.

create table public.platform_admin (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.platform_admin enable row level security;

create policy platform_admin_self on public.platform_admin
  for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.platform_admin where user_id = (select auth.uid()));
$$;
revoke execute on function app.is_platform_admin() from public, anon;
grant execute on function app.is_platform_admin() to authenticated;

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
set search_path = ''
as $$ select app.is_platform_admin(); $$;
revoke execute on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;

create or replace function app.assert_platform_admin()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not app.is_platform_admin() then
    raise exception 'FORBIDDEN' using errcode = '42501', hint = 'Only Seena platform admins can do this.';
  end if;
end;
$$;
revoke execute on function app.assert_platform_admin() from public, anon;
grant execute on function app.assert_platform_admin() to authenticated;

-- ── list ──────────────────────────────────────────────────────────────────

create or replace function public.platform_list_tenants()
returns table (
  id              uuid,
  slug            text,
  name            text,
  status          public.tenant_status,
  created_at      timestamptz,
  campuses        int,
  students        int,
  logins          int,
  owner_name      text,
  owner_email     text,
  owner_invite_id uuid,
  last_sign_in_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform app.assert_platform_admin();
  return query
  select t.id,
         t.slug,
         t.name,
         t.status,
         t.created_at,
         (select count(*)::int from public.campus c where c.tenant_id = t.id and c.deleted_at is null),
         (select count(*)::int from public.student s where s.tenant_id = t.id and s.status = 'active'),
         (select count(*)::int from public.app_user au where au.tenant_id = t.id and au.status = 'active'),
         (select au.full_name from public.app_user au
           where au.tenant_id = t.id and au.app_role = 'owner' order by au.created_at limit 1),
         coalesce(
           (select u.email::text from public.app_user au join auth.users u on u.id = au.user_id
             where au.tenant_id = t.id and au.app_role = 'owner' order by au.created_at limit 1),
           (select i.email::text from public.tenant_invitation i
             where i.tenant_id = t.id and i.app_role = 'owner' order by i.created_at desc limit 1)
         ),
         (select i.id from public.tenant_invitation i
           where i.tenant_id = t.id and i.app_role = 'owner' and i.accepted_at is null
           order by i.created_at desc limit 1),
         (select max(u.last_sign_in_at) from public.app_user au join auth.users u on u.id = au.user_id
           where au.tenant_id = t.id)
    from public.tenant t
   where t.deleted_at is null
   order by t.created_at desc;
end;
$$;
revoke execute on function public.platform_list_tenants() from public, anon;
grant execute on function public.platform_list_tenants() to authenticated;

-- ── provision ─────────────────────────────────────────────────────────────

create or replace function public.platform_provision_tenant(p_slug text, p_legal_name text, p_owner_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_platform_admin();
  return public.provision_tenant(p_slug, p_legal_name, p_owner_email);
end;
$$;
revoke execute on function public.platform_provision_tenant(text, text, text) from public, anon;
grant execute on function public.platform_provision_tenant(text, text, text) to authenticated;

-- ── owner invitation: a fresh link every time it is (re)sent ──────────────
-- Invitations expire after 14 days; resending an expired token would only
-- produce a link that accept_invitation() refuses.

create or replace function public.platform_renew_owner_invite(p_tenant_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.assert_platform_admin();
  update public.tenant_invitation
     set token = encode(extensions.gen_random_bytes(24), 'hex'),
         expires_at = now() + interval '14 days'
   where id = (select i.id from public.tenant_invitation i
                where i.tenant_id = p_tenant_id and i.app_role = 'owner' and i.accepted_at is null
                order by i.created_at desc limit 1)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.platform_renew_owner_invite(uuid) from public, anon;
grant execute on function public.platform_renew_owner_invite(uuid) to authenticated;

-- ── suspend / reactivate / close ──────────────────────────────────────────

create or replace function public.platform_set_tenant_status(
  p_tenant_id uuid,
  p_status    public.tenant_status,
  p_reason    text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.tenant_status;
begin
  perform app.assert_platform_admin();

  if p_status not in ('active', 'suspended', 'closed') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'REASON_REQUIRED' using errcode = '22023', hint = 'Say why the school''s status is changing.';
  end if;

  select status into v_old from public.tenant where id = p_tenant_id and deleted_at is null for update;
  if not found then
    raise exception 'TENANT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_old = 'closed' then
    raise exception 'TENANT_CLOSED' using errcode = '22023', hint = 'A closed school cannot be reopened.';
  end if;
  if v_old = p_status then
    return;
  end if;

  update public.tenant set status = p_status where id = p_tenant_id;

  -- Live staff tokens go stale now, whichever way the status moved: a
  -- reactivated school must re-mint too, or its users keep a tenant-less token.
  update public.app_user set claims_version = claims_version + 1 where tenant_id = p_tenant_id;

  insert into public.audit_log (tenant_id, actor_user_id, action, table_name, row_id, before, after, changed_columns)
  values (p_tenant_id, (select auth.uid()), 'update', 'tenant', p_tenant_id,
          jsonb_build_object('status', v_old),
          jsonb_build_object('status', p_status, 'reason', trim(p_reason), 'by', 'platform_admin'),
          array['status']);
end;
$$;
revoke execute on function public.platform_set_tenant_status(uuid, public.tenant_status, text) from public, anon;
grant execute on function public.platform_set_tenant_status(uuid, public.tenant_status, text) to authenticated;

-- ── which school is this account in, whatever its kind ────────────────────
-- Used by /no-school to tell "your school is suspended" apart from "you are not
-- in a school". Reads the caller's own memberships only.

create or replace function public.my_school_status()
returns table (tenant_name text, status public.tenant_status, account_active boolean)
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select au.tenant_id, au.status = 'active' as active from public.app_user au where au.user_id = (select auth.uid())
    union all
    select g.tenant_id, true from public.guardian g where g.auth_user_id = (select auth.uid())
    union all
    select spa.tenant_id, spa.status = 'active' from public.student_portal_account spa where spa.user_id = (select auth.uid())
  )
  select t.name, t.status, me.active
    from me join public.tenant t on t.id = me.tenant_id
   limit 1;
$$;
revoke execute on function public.my_school_status() from public, anon;
grant execute on function public.my_school_status() to authenticated;

-- ── token hook: no tenant claims for a school that is not active ──────────
-- The resolver body stays as it was, renamed; the hook Supabase calls wraps it.
-- A later migration that wants to change claim resolution must replace
-- custom_access_token_base, not custom_access_token_hook, or it drops this gate.

alter function public.custom_access_token_hook(jsonb) rename to custom_access_token_base;
revoke execute on function public.custom_access_token_base(jsonb) from public, anon, authenticated;
grant execute on function public.custom_access_token_base(jsonb) to supabase_auth_admin;

create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_event  jsonb := public.custom_access_token_base(event);
  v_tenant uuid;
begin
  if v_event ? 'error' then
    return v_event;
  end if;

  v_tenant := nullif(v_event #>> '{claims,tenant_id}', '')::uuid;
  if v_tenant is not null
     and not exists (select 1 from public.tenant t where t.id = v_tenant and t.status = 'active' and t.deleted_at is null) then
    return jsonb_set(v_event, '{claims}',
      ((v_event -> 'claims') - 'campus_ids' - 'academic_session_id' - 'role_id' - 'imp' - 'student_id')
        || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
  end if;

  return v_event;
exception
  when others then
    return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'AUTH_CLAIMS_UNAVAILABLE'));
end;
$$;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
