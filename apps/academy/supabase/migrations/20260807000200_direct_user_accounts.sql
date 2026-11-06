-- Direct user accounts: an Owner or Principal creates a staff login with a
-- username and a temporary password, no email invitation needed, and manages
-- every login in the school (staff, parents, students) from one screen.
--
-- Usernames. Supabase Auth needs an email per account, so a username account
-- gets a hidden address '<username>@<school slug>.users.seena.local'. The person
-- signs in with 'username@slug'; app/login/actions.ts expands it. Usernames
-- are unique per school.
--
-- Creating the auth user needs the service-role key, so it happens in the
-- server action between two calls made as the signed-in Owner/Principal:
--   1. user_account_login_email()  checks the caller may create the account and
--                                  the username is free; returns the address.
--   2. (service role) auth.admin.createUser(address, temporary password)
--   3. create_user_account()       re-checks everything and links the new auth
--                                  user. It only accepts an auth user created in
--                                  the last 10 minutes that belongs to nobody, and
--                                  for a username account only the expected
--                                  address, so it cannot be used to pull an
--                                  existing account into another school.
--
-- "Must change password on next sign-in" lives in auth app_metadata
-- (must_change_password), set by the service role and enforced in middleware.ts,
-- so it covers staff and parents alike. Students keep their own column.

alter table public.app_user add column username public.citext;
alter table public.app_user
  add constraint app_user_username_format check (username is null or username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
create unique index app_user_username_uniq on public.app_user (tenant_id, username) where username is not null;

create or replace function app.fn_username_email(p_username text, p_slug text)
returns text
language sql
immutable
set search_path = ''
as $$ select lower(p_username) || '@' || lower(p_slug) || '.users.seena.local'; $$;

create or replace function app.assert_can_create_account(p_role public.app_role, p_campus_ids uuid[])
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_can_grant_role(app.auth_role(), p_role::text) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'your role cannot grant that role';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_campus_ids, '{}')) c(id)
     where not exists (select 1 from public.campus where id = c.id and tenant_id = v_tenant_id and deleted_at is null)
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return v_tenant_id;
end;
$$;
revoke execute on function app.assert_can_create_account(public.app_role, uuid[]) from public, anon;
grant execute on function app.assert_can_create_account(public.app_role, uuid[]) to authenticated;

create or replace function public.user_account_login_email(
  p_username   text,
  p_role       public.app_role,
  p_campus_ids uuid[]
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.assert_can_create_account(p_role, p_campus_ids);
  v_slug      text;
begin
  -- Called with no username, it only answers "may the caller create this account".
  if p_username is null then
    return null;
  end if;
  if lower(p_username) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then
    raise exception 'USERNAME_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.app_user where tenant_id = v_tenant_id and username = lower(p_username)::public.citext) then
    raise exception 'USERNAME_TAKEN' using errcode = '23505';
  end if;
  select slug into v_slug from public.tenant where id = v_tenant_id;
  return app.fn_username_email(p_username, v_slug);
end;
$$;
revoke execute on function public.user_account_login_email(text, public.app_role, uuid[]) from public, anon;
grant execute on function public.user_account_login_email(text, public.app_role, uuid[]) to authenticated;

create or replace function public.create_user_account(
  p_user_id    uuid,
  p_full_name  text,
  p_role       public.app_role,
  p_campus_ids uuid[],
  p_username   text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.assert_can_create_account(p_role, p_campus_ids);
  v_auth      record;
  v_slug      text;
begin
  if nullif(trim(coalesce(p_full_name, '')), '') is null then
    raise exception 'NAME_REQUIRED' using errcode = '22023';
  end if;

  select id, email, created_at into v_auth from auth.users where id = p_user_id;
  if not found
     or v_auth.created_at < now() - interval '10 minutes'
     or exists (select 1 from public.app_user where user_id = p_user_id)
     or exists (select 1 from public.guardian where auth_user_id = p_user_id)
     or exists (select 1 from public.student_portal_account where user_id = p_user_id)
     or exists (select 1 from public.platform_admin where user_id = p_user_id) then
    raise exception 'ACCOUNT_NOT_LINKABLE' using errcode = '42501';
  end if;

  if p_username is not null then
    select slug into v_slug from public.tenant where id = v_tenant_id;
    if v_auth.email is distinct from app.fn_username_email(p_username, v_slug) then
      raise exception 'ACCOUNT_NOT_LINKABLE' using errcode = '42501';
    end if;
  end if;

  insert into public.app_user (user_id, tenant_id, app_role, full_name, username)
  values (p_user_id, v_tenant_id, p_role, trim(p_full_name), lower(p_username));

  insert into public.user_campus (user_id, tenant_id, campus_id)
  select p_user_id, v_tenant_id, c.id from unnest(coalesce(p_campus_ids, '{}')) c(id);

  insert into public.audit_log (tenant_id, actor_user_id, actor_role, action, table_name, row_id, after)
  values (v_tenant_id, (select auth.uid()), app.auth_role()::public.app_role, 'insert', 'app_user', p_user_id,
          jsonb_build_object('app_role', p_role, 'username', lower(p_username), 'created_directly', true));
end;
$$;
revoke execute on function public.create_user_account(uuid, text, public.app_role, uuid[], text) from public, anon;
grant execute on function public.create_user_account(uuid, text, public.app_role, uuid[], text) to authenticated;

-- ── which accounts may the caller manage ──────────────────────────────────
-- Staff: only people ranked below the caller (a super_admin may manage anyone
-- but themselves). Parents and students: any Owner/Principal of their school.

create or replace function public.user_account_kind(p_user_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_target    text;
begin
  if v_tenant_id is null or v_role not in ('owner', 'principal', 'super_admin') or p_user_id = (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select au.app_role::text into v_target from public.app_user au where au.user_id = p_user_id and au.tenant_id = v_tenant_id;
  if found then
    if v_role <> 'super_admin' and app.fn_role_rank(v_role) <= app.fn_role_rank(v_target) then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'you can only manage accounts ranked below you';
    end if;
    return 'staff';
  end if;
  if exists (select 1 from public.student_portal_account where user_id = p_user_id and tenant_id = v_tenant_id) then
    return 'student';
  end if;
  if exists (select 1 from public.guardian where auth_user_id = p_user_id and tenant_id = v_tenant_id) then
    return 'parent';
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501';
end;
$$;
revoke execute on function public.user_account_kind(uuid) from public, anon;
grant execute on function public.user_account_kind(uuid) to authenticated;

create or replace function public.set_user_account_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := public.user_account_kind(p_user_id);
begin
  if v_kind = 'staff' then
    update public.app_user set status = case when p_active then 'active' else 'suspended' end::public.user_status
     where user_id = p_user_id;
  elsif v_kind = 'student' then
    update public.student_portal_account
       set status = case when p_active then 'active' else 'disabled' end, updated_at = clock_timestamp()
     where user_id = p_user_id;
  else
    raise exception 'NOT_SUPPORTED' using errcode = '22023', hint = 'Parent logins are turned off by unlinking the parent from the student.';
  end if;

  insert into public.audit_log (tenant_id, actor_user_id, actor_role, action, table_name, row_id, after)
  values (app.auth_tenant_id(), (select auth.uid()), app.auth_role()::public.app_role, 'update',
          case v_kind when 'staff' then 'app_user' else 'student_portal_account' end, p_user_id,
          jsonb_build_object('active', p_active));
end;
$$;
revoke execute on function public.set_user_account_active(uuid, boolean) from public, anon;
grant execute on function public.set_user_account_active(uuid, boolean) to authenticated;

create or replace function public.set_user_account_role(p_user_id uuid, p_role public.app_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.user_account_kind(p_user_id) <> 'staff' then
    raise exception 'NOT_SUPPORTED' using errcode = '22023';
  end if;
  if not app.fn_can_grant_role(app.auth_role(), p_role::text) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'your role cannot grant that role';
  end if;
  update public.app_user set app_role = p_role where user_id = p_user_id;

  insert into public.audit_log (tenant_id, actor_user_id, actor_role, action, table_name, row_id, after, changed_columns)
  values (app.auth_tenant_id(), (select auth.uid()), app.auth_role()::public.app_role, 'update', 'app_user', p_user_id,
          jsonb_build_object('app_role', p_role), array['app_role']);
end;
$$;
revoke execute on function public.set_user_account_role(uuid, public.app_role) from public, anon;
grant execute on function public.set_user_account_role(uuid, public.app_role) to authenticated;

-- ── list ──────────────────────────────────────────────────────────────────

create or replace function public.list_user_accounts()
returns table (
  user_id         uuid,
  kind            text,
  full_name       text,
  app_role        text,
  active          boolean,
  login_id        text,
  campuses        text[],
  last_sign_in_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_slug      text;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select slug into v_slug from public.tenant where id = v_tenant_id;

  return query
  select au.user_id, 'staff', au.full_name, au.app_role::text, au.status = 'active',
         coalesce(au.username::text || '@' || v_slug, u.email::text),
         coalesce((select array_agg(c.name order by c.name) from public.user_campus uc
                     join public.campus c on c.id = uc.campus_id
                    where uc.user_id = au.user_id and uc.is_active), '{}'),
         u.last_sign_in_at
    from public.app_user au
    join auth.users u on u.id = au.user_id
   where au.tenant_id = v_tenant_id
  union all
  select g.auth_user_id, 'parent', g.name_en, 'parent', true, coalesce(u.email::text, u.phone::text), '{}'::text[], u.last_sign_in_at
    from public.guardian g
    join auth.users u on u.id = g.auth_user_id
   where g.tenant_id = v_tenant_id
  union all
  select spa.user_id, 'student', s.name_en, 'student', spa.status = 'active', s.gr_number,
         array[c.name], u.last_sign_in_at
    from public.student_portal_account spa
    join public.student s on s.id = spa.student_id
    join public.campus c on c.id = spa.campus_id
    join auth.users u on u.id = spa.user_id
   where spa.tenant_id = v_tenant_id
  order by 2 desc, 3;
end;
$$;
revoke execute on function public.list_user_accounts() from public, anon;
grant execute on function public.list_user_accounts() to authenticated;
