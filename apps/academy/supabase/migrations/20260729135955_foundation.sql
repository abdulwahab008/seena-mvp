-- Foundation: tenant, campus, academic_session, app_user, RLS helpers,
-- JWT custom-claims hook, audit_log. Implements FR-A01 (tenant provisioning)
-- and FR-A02 (campus provisioning). See docs/data-model.md and docs/rls.md
-- for the full design this is derived from.
--
-- Scoping decisions made while turning those two independently-written docs
-- into one migration:
--   * app_user carries a single `app_role` enum column (RLS doc's design),
--     not the more general role/user_role_assignment many-to-many table
--     data-model.md sketches. One role per user account is a deliberate
--     simplicity choice; revisit only if a real tenant needs custom roles.
--   * audit_log is a plain table, not yet range-partitioned by month —
--     partitioning is a scale optimization, add it when volume warrants.
--   * The custom_access_token_hook's break-glass/support-impersonation
--     overlay (rls.md §7) is intentionally omitted — no support tooling
--     exists yet to grant it, and shipping the overlay without the tooling
--     that populates platform.support_grant is dead code.
--   * IDs are gen_random_uuid() (v4), not UUID v7 — v7's benefit is index
--     locality under high insert rates; not a correctness concern yet.

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ── Schemas ─────────────────────────────────────────────────────────────

create schema if not exists app;
revoke all on schema app from public;
grant usage on schema app to authenticated, anon, service_role;

-- ── Enums ───────────────────────────────────────────────────────────────

create type public.tenant_status as enum ('provisioning', 'active', 'suspended', 'closed');
create type public.campus_status as enum ('active', 'archived');
create type public.session_status as enum ('planned', 'active', 'closed', 'archived');
create type public.app_role as enum (
  'super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer',
  'accountant', 'exam_controller', 'head_of_department', 'class_teacher',
  'subject_teacher', 'hr_manager', 'librarian', 'transport_manager',
  'receptionist', 'parent', 'student'
);
create type public.user_status as enum ('active', 'suspended', 'terminated');
create type public.audit_action as enum ('insert', 'update', 'delete');

-- ── tenant ──────────────────────────────────────────────────────────────

create table public.tenant (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null,
  name         text not null,
  name_ur      text,
  legal_name   text,
  country_code text not null default 'PK',
  timezone     text not null default 'Asia/Karachi',
  currency     text not null default 'PKR',
  locale       text not null default 'en-PK',
  status       public.tenant_status not null default 'provisioning',
  settings     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz
);

-- Slug uniqueness spans soft-deleted rows so a restored/renamed tenant can
-- never collide with a live one (FR-A01 acceptance criteria).
create unique index tenant_slug_uniq on public.tenant (lower(slug));
alter table public.tenant
  add constraint tenant_slug_format check (slug ~ '^[a-z0-9][a-z0-9-]{2,49}$');

create table public.tenant_setting (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, key)
);

-- ── campus ──────────────────────────────────────────────────────────────

create table public.campus (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  code         text not null,
  name         text not null,
  name_ur      text,
  address_line text,
  city         text,
  district     text,
  phone_e164   text,
  timezone     text not null default 'Asia/Karachi',
  day_start    time not null default '08:00',
  day_end      time not null default '14:00',
  working_days smallint[] not null default '{1,2,3,4,5,6}', -- 1=Mon .. 7=Sun (ISO)
  status       public.campus_status not null default 'active',
  created_at   timestamptz not null default now(),
  deleted_at   timestamptz
);

create unique index campus_code_uniq on public.campus (tenant_id, upper(code));
create index campus_tenant_idx on public.campus (tenant_id);

create table public.campus_setting (
  campus_id  uuid not null references public.campus(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  created_at timestamptz not null default now(),
  primary key (campus_id, key)
);

create table public.campus_bank_account (
  id          uuid primary key default gen_random_uuid(),
  campus_id   uuid not null references public.campus(id) on delete cascade,
  bank_name   text not null,
  title       text not null,
  account_no  text not null,
  iban        text,
  branch_code text,
  is_default  boolean not null default false,
  created_at  timestamptz not null default now()
);

create index campus_bank_account_campus_idx on public.campus_bank_account (campus_id);

-- A tenant can have at most 50 campuses (FR-A02). Enforced in the
-- provisioning path rather than a CHECK constraint, since a CHECK cannot
-- see sibling rows.

-- ── academic_session ────────────────────────────────────────────────────

create table public.academic_session (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid references public.campus(id) on delete cascade, -- null = shared by all campuses
  name               text not null,
  starts_on          date not null,
  ends_on            date not null,
  is_current         boolean not null default false,
  admission_opens_on date,
  result_locked_at   timestamptz,
  status             public.session_status not null default 'planned',
  created_at         timestamptz not null default now(),
  constraint academic_session_dates_chk check (ends_on > starts_on)
);

create index academic_session_tenant_idx on public.academic_session (tenant_id);
-- At most one current session per (tenant, campus); a null campus_id
-- session is tenant-wide, so partial-index it separately.
create unique index academic_session_current_per_campus_uniq
  on public.academic_session (tenant_id, campus_id)
  where is_current and campus_id is not null;
create unique index academic_session_current_tenant_wide_uniq
  on public.academic_session (tenant_id)
  where is_current and campus_id is null;

-- KNOWN LIMITATION: custom_access_token_hook below picks the tenant's
-- current session with no campus filter and no deterministic order. That is
-- fine while every tenant has exactly one (campus-scoped) current session,
-- which is all provision_tenant() ever creates. It stops being fine once a
-- multi-campus tenant can mark a *different* current session per campus —
-- fix this when FR-A04 (academic session lifecycle) ships, by filtering on
-- the user's working/primary campus instead of `limit 1`.

-- ── app_user / user_campus ──────────────────────────────────────────────

create table public.app_user (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  tenant_id      uuid not null references public.tenant(id),
  app_role       public.app_role not null,
  full_name      text not null,
  phone_e164     text,
  status         public.user_status not null default 'active',
  claims_version int not null default 1,
  created_at     timestamptz not null default now()
);

create index app_user_tenant_idx on public.app_user (tenant_id);

-- tenant_id is immutable once set — moving school groups means a new account.
create or replace function app.tg_app_user_tenant_immutable()
returns trigger
language plpgsql
as $$
begin
  if new.tenant_id <> old.tenant_id then
    raise exception 'app_user.tenant_id is immutable (got % -> %)', old.tenant_id, new.tenant_id;
  end if;
  return new;
end;
$$;

create trigger app_user_tenant_immutable
  before update of tenant_id on public.app_user
  for each row execute function app.tg_app_user_tenant_immutable();

create table public.user_campus (
  user_id   uuid not null references public.app_user(user_id) on delete cascade,
  tenant_id uuid not null,
  campus_id uuid not null references public.campus(id) on delete cascade,
  is_active boolean not null default true,
  primary key (user_id, campus_id)
);

create index user_campus_user_idx on public.user_campus (user_id);

-- ── tenant_invitation ───────────────────────────────────────────────────
-- Minimal invite record so FR-A01's "one Owner user invitation" acceptance
-- criterion is satisfiable. The send-email / accept-and-create-app_user flow
-- is out of scope for this migration (belongs with the onboarding /
-- staff-invite work) — this table is the row that flow will consume.

create table public.tenant_invitation (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  email            citext not null,
  app_role         public.app_role not null,
  token            text not null default encode(gen_random_bytes(24), 'hex'),
  invited_by       uuid references public.app_user(user_id),
  expires_at       timestamptz not null default (now() + interval '14 days'),
  accepted_at      timestamptz,
  accepted_user_id uuid references public.app_user(user_id),
  created_at       timestamptz not null default now()
);

create unique index tenant_invitation_token_uniq on public.tenant_invitation (token);
create index tenant_invitation_tenant_idx on public.tenant_invitation (tenant_id);

-- ── audit_log ────────────────────────────────────────────────────────────

create table public.audit_log (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null,
  campus_id       uuid,
  occurred_at     timestamptz not null default now(),
  actor_user_id   uuid,
  actor_role      public.app_role,
  action          public.audit_action not null,
  table_name      text not null,
  row_id          uuid,
  before          jsonb,
  after           jsonb,
  changed_columns text[]
);

create index audit_log_tenant_idx on public.audit_log (tenant_id, occurred_at desc);

-- Generic per-row audit trigger. Not yet attached to any table in this
-- migration (tenant/campus writes go through provision_tenant/
-- archive_campus, which are already access-controlled) — later migrations
-- attach it to student/enrolment/mark/challan/etc. with
-- `create trigger ... execute function app.tg_audit_row()`.
create or replace function app.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_row_id    uuid;
  v_changed   text[];
begin
  v_tenant_id := coalesce((to_jsonb(new)->>'tenant_id')::uuid, (to_jsonb(old)->>'tenant_id')::uuid);
  v_row_id    := coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid);

  if tg_op = 'UPDATE' then
    select array_agg(key) into v_changed
      from jsonb_each(to_jsonb(new))
     where to_jsonb(new)->key is distinct from to_jsonb(old)->key;
  end if;

  insert into public.audit_log (
    tenant_id, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns
  ) values (
    v_tenant_id,
    (select auth.uid()),
    nullif(app.auth_role(), 'none')::public.app_role,
    lower(tg_op)::public.audit_action,
    tg_table_name,
    v_row_id,
    case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end,
    case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end,
    v_changed
  );

  return coalesce(new, old);
end;
$$;

-- ── app.* helper functions (RLS building blocks) ────────────────────────

create or replace function app.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb,
    '{}'::jsonb
  );
$$;

create or replace function app.auth_tenant_id()
returns uuid
language sql
stable
as $$
  select nullif(app.jwt() ->> 'tenant_id', '')::uuid;
$$;

create or replace function app.auth_campus_ids()
returns uuid[]
language sql
stable
as $$
  select coalesce(
    (select array_agg(v::uuid)
       from jsonb_array_elements_text(coalesce(app.jwt() -> 'campus_ids', '[]'::jsonb)) as t(v)),
    '{}'::uuid[]
  );
$$;

create or replace function app.auth_role()
returns text
language sql
stable
as $$
  select coalesce(app.jwt() ->> 'app_role', 'none');
$$;

create or replace function app.auth_session_id()
returns uuid
language sql
stable
as $$
  select nullif(app.jwt() ->> 'academic_session_id', '')::uuid;
$$;

revoke execute on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated;

-- ── custom_access_token_hook ─────────────────────────────────────────────

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
           limit 1) as academic_session_id
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
    'cv',                  u.claims_version
  );

  return jsonb_set(event, '{claims}', claims);
end;
$$;

grant usage on schema public to supabase_auth_admin;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;
revoke execute on function public.custom_access_token_hook(jsonb) from authenticated, anon, public;
grant select on public.app_user, public.user_campus, public.academic_session to supabase_auth_admin;

-- ── RLS ──────────────────────────────────────────────────────────────────

alter table public.tenant enable row level security;
alter table public.tenant_setting enable row level security;
alter table public.campus enable row level security;
alter table public.campus_setting enable row level security;
alter table public.campus_bank_account enable row level security;
alter table public.academic_session enable row level security;
alter table public.app_user enable row level security;
alter table public.user_campus enable row level security;
alter table public.tenant_invitation enable row level security;
alter table public.audit_log enable row level security;

-- tenant: a member reads only their own tenant. All writes go through
-- SECURITY DEFINER functions (provision_tenant, archive_campus), never
-- direct DML — so there is deliberately no INSERT/UPDATE policy here for
-- authenticated users.
create policy tenant_self_read on public.tenant
  for select to authenticated
  using (id = app.auth_tenant_id());

create policy tenant_setting_tenant_scope on public.tenant_setting
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy campus_tenant_scope on public.campus
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy campus_setting_scope on public.campus_setting
  for select to authenticated
  using (campus_id in (select id from public.campus where tenant_id = app.auth_tenant_id()));

create policy campus_bank_account_scope on public.campus_bank_account
  for select to authenticated
  using (
    app.auth_role() in ('owner', 'principal', 'accountant', 'super_admin')
    and campus_id in (select id from public.campus where tenant_id = app.auth_tenant_id())
  );

create policy academic_session_tenant_scope on public.academic_session
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy app_user_tenant_scope on public.app_user
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy user_campus_tenant_scope on public.user_campus
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy tenant_invitation_admin_scope on public.tenant_invitation
  for select to authenticated
  using (
    app.auth_role() in ('owner', 'super_admin')
    and tenant_id = app.auth_tenant_id()
  );

create policy audit_log_tenant_scope on public.audit_log
  for select to authenticated
  using (
    app.auth_role() in ('owner', 'principal', 'super_admin')
    and tenant_id = app.auth_tenant_id()
  );

-- ── provision_tenant (FR-A01) ────────────────────────────────────────────
-- Callable only by the service role (Super Admin action via the backend
-- admin API) — never directly by an authenticated end user.

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

-- ── archive_campus (FR-A02) ──────────────────────────────────────────────
-- Callable by an authenticated Owner/Super Admin; enforces its own
-- authorization since PostgREST RPCs run as `authenticated`, not the caller.

create or replace function public.archive_campus(p_campus_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id <> app.auth_tenant_id() or app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.campus set status = 'archived', deleted_at = now() where id = p_campus_id;
  update public.user_campus set is_active = false where campus_id = p_campus_id;
end;
$$;

revoke execute on function public.archive_campus(uuid) from public, anon;
grant execute on function public.archive_campus(uuid) to authenticated;
