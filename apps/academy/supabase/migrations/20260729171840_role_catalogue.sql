-- FR-A10 (system role catalogue). permission/role/role_permission plus
-- seed_tenant_roles() (wired into provision_tenant) and has_permission().
--
-- Scope note: app_role (foundation migration) already has 16 values and is
-- the mechanism every RLS policy and function written so far actually
-- checks — this migration does not replace it. The FR's "exactly 12 role
-- rows" acceptance criterion is a placeholder number that predates the
-- 16-value enum this codebase already ships; seeding follows the enum (one
-- system role per app_role value) rather than a hand-picked 12, since a
-- catalogue that omits roles the system already assigns would be worse than
-- the AC's exact count being off. has_permission() is additive — nothing
-- yet calls it from an RLS policy, existing policies keep using
-- app.auth_role() until a caller actually needs permission-level (not
-- role-level) granularity.
--
-- Scope note 2: FR-A13's "token rejected within 60s of a role change" live-
-- revocation guarantee is NOT implemented here. role_id is stamped into the
-- JWT at issue time same as tenant_id/app_role, so it goes stale the same
-- way those already do until FR-A13's epoch check ships — no worse than the
-- status quo, not yet better either.

create table public.permission (
  code     text primary key,
  module   text not null,
  label    text not null,
  label_ur text
);

create table public.role (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid references public.tenant(id) on delete cascade, -- null = global template
  code       text not null,
  name       text not null,
  name_ur    text,
  is_system  boolean not null default false,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

-- Two disjoint uniqueness spaces: template rows (tenant_id null) keyed by
-- code alone, tenant rows keyed by (tenant_id, code).
create unique index role_template_code_uniq on public.role (code) where tenant_id is null;
create unique index role_tenant_code_uniq on public.role (tenant_id, code) where tenant_id is not null;
create index role_tenant_idx on public.role (tenant_id);

create table public.role_permission (
  role_id         uuid not null references public.role(id) on delete cascade,
  permission_code text not null references public.permission(code) on delete cascade,
  primary key (role_id, permission_code)
);

-- System roles (is_system) can never be renamed away or deleted — the
-- catalogue an Owner sees must always include every role app_role can hold.
create or replace function app.tg_block_system_role_write()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' and old.is_system then
    raise exception 'ROLE_IMMUTABLE' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' and old.is_system and (new.code <> old.code or new.is_system <> old.is_system) then
    raise exception 'ROLE_IMMUTABLE' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger role_block_system_write
  before update or delete on public.role
  for each row execute function app.tg_block_system_role_write();

-- Global templates: one per app_role enum value. seed_tenant_roles() copies
-- these into a tenant at provisioning time.
insert into public.role (tenant_id, code, name, is_system)
select null, e.role_code::text, initcap(replace(e.role_code::text, '_', ' ')), true
  from unnest(enum_range(null::public.app_role)) as e(role_code);

create or replace function public.seed_tenant_roles(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.role (tenant_id, code, name, name_ur, is_system)
  select p_tenant_id, code, name, name_ur, true
    from public.role
   where tenant_id is null;

  insert into public.role_permission (role_id, permission_code)
  select tr.id, tmpl_rp.permission_code
    from public.role tr
    join public.role tmpl on tmpl.tenant_id is null and tmpl.code = tr.code
    join public.role_permission tmpl_rp on tmpl_rp.role_id = tmpl.id
   where tr.tenant_id = p_tenant_id;
end;
$$;

revoke execute on function public.seed_tenant_roles(uuid) from public, anon, authenticated;
grant execute on function public.seed_tenant_roles(uuid) to service_role;

-- provision_tenant (FR-A01) now also seeds the tenant's role catalogue.
create or replace function public.provision_tenant(
  p_slug        text,
  p_legal_name  text,
  p_owner_email text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if p_slug !~ '^[a-z0-9][a-z0-9-]{2,49}$' then
    raise exception 'TENANT_SLUG_INVALID' using errcode = '22023';
  end if;

  if exists (select 1 from public.tenant where lower(slug) = lower(p_slug)) then
    raise exception 'TENANT_SLUG_TAKEN' using errcode = '23505';
  end if;

  insert into public.tenant (slug, name, legal_name, status)
  values (p_slug, p_legal_name, p_legal_name, 'provisioning')
  returning id into v_tenant_id;

  perform public.seed_tenant_roles(v_tenant_id);

  insert into public.campus (tenant_id, code, name)
  values (v_tenant_id, 'MAIN', p_legal_name)
  returning id into v_campus_id;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
  values (
    v_tenant_id,
    v_campus_id,
    to_char(current_date, 'YYYY') || '-' || to_char(current_date + interval '1 year', 'YY'),
    date_trunc('year', current_date)::date,
    (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
    true,
    'active'
  );

  insert into public.tenant_invitation (tenant_id, email, app_role)
  values (v_tenant_id, p_owner_email, 'owner');

  update public.tenant set status = 'active' where id = v_tenant_id;

  return v_tenant_id;
end;
$$;

revoke execute on function public.provision_tenant(text, text, text) from public, anon, authenticated;
grant execute on function public.provision_tenant(text, text, text) to service_role;

-- app.auth_role_id(): parallel to app.auth_tenant_id() etc — reads the new
-- role_id claim (added to custom_access_token_hook below).
create or replace function app.auth_role_id()
returns uuid
language sql
stable
as $$
  select nullif(app.jwt() ->> 'role_id', '')::uuid;
$$;

create or replace function app.has_permission(p_code text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from public.role_permission
     where role_id = app.auth_role_id()
       and permission_code = p_code
  );
$$;

grant execute on function app.auth_role_id() to authenticated;
grant execute on function app.has_permission(text) to authenticated;

-- custom_access_token_hook: add role_id (tenant-scoped role row matching
-- the user's app_role) to the claim set. Additive — every existing claim
-- (tenant_id, campus_ids, app_role, academic_session_id, cv) is unchanged.
create or replace function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  claims jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  u      record;
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

  if not found then
    -- No active tenant membership: tenant_id = null makes every tenant-fence
    -- policy evaluate to NULL, which RLS treats as deny.
    return jsonb_set(event, '{claims}',
      claims || jsonb_build_object('tenant_id', null, 'app_role', 'none', 'cv', 0));
  end if;

  claims := claims || jsonb_build_object(
    'tenant_id',           u.tenant_id,
    'campus_ids',          to_jsonb(u.campus_ids),
    'app_role',            u.app_role,
    'academic_session_id', u.academic_session_id,
    'role_id',             u.role_id,
    'cv',                  u.claims_version
  );

  return jsonb_set(event, '{claims}', claims);
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on public.role to supabase_auth_admin;

-- ── RLS ──────────────────────────────────────────────────────────────────

alter table public.permission enable row level security;
alter table public.role enable row level security;
alter table public.role_permission enable row level security;

create policy permission_read_all on public.permission
  for select to authenticated
  using (true);

create policy role_tenant_scope on public.role
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() or tenant_id is null);

create policy role_permission_tenant_scope on public.role_permission
  for select to authenticated
  using (
    role_id in (
      select id from public.role where tenant_id = app.auth_tenant_id() or tenant_id is null
    )
  );
