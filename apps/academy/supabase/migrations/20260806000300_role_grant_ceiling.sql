-- Roles: nobody can hand out a role above their own, or lock a superior out.
--
-- 1. invite_user() checked who the caller was and never what role they were granting. The
--    invitation form offers six roles, but the function behind it (and register_staff_member(),
--    which calls it) accepted any value of app_role, so a Principal could invite an Owner or a
--    platform Super Admin and accept the invitation themselves: a working account with more
--    authority than the person who created it. It now enforces a ceiling:
--      super_admin  any staff role
--      owner        any staff role except super_admin
--      principal    any staff role except super_admin and owner
--    parent and student are not staff roles and can never be invited. accept_invitation() refuses
--    such an invitation too.
--
-- 2. assign_custom_role() let anyone holding role.manage put a custom role on anyone in the school.
--    A custom role narrows its holder, so a Principal could assign a near-empty one to the Owner,
--    who then could not clear it (clearing needs role.manage, which was just removed). It can now
--    only be put on someone ranked below the caller (super admin may assign to anyone).
--
-- 3. role and role_permission had a FOR ALL policy for anyone with role.manage, so a direct insert
--    skipped the "no more than you hold" check that create_custom_role() makes. The application
--    never writes those tables directly (it calls the functions), so the write policies are dropped;
--    the SECURITY DEFINER functions are unaffected.

create or replace function app.fn_role_rank(p_role text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_role
    when 'super_admin' then 4
    when 'owner'       then 3
    when 'principal'   then 2
    when 'parent'      then 0
    when 'student'     then 0
    when 'none'        then 0
    else 1
  end;
$$;

create or replace function app.fn_can_grant_role(p_grantor text, p_target text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select case
    when p_target in ('parent', 'student', 'none') then false
    when p_grantor = 'super_admin' then true
    when p_grantor = 'owner'       then p_target <> 'super_admin'
    when p_grantor = 'principal'   then p_target not in ('super_admin', 'owner')
    else false
  end;
$$;

create or replace function public.invite_user(
  p_email      public.citext,
  p_role       public.app_role,
  p_campus_ids uuid[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_inviter   uuid;
  v_invite_id uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A caller may only hand out roles at or below their own (see app.fn_can_grant_role).
  if not app.fn_can_grant_role(app.auth_role(), p_role::text) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'your role cannot grant that role';
  end if;

  select user_id into v_inviter from public.app_user where user_id = (select auth.uid());

  if p_campus_ids <> '{}' and exists (
    select 1 from unnest(p_campus_ids) c(id)
    where not exists (select 1 from public.campus where id = c.id and tenant_id = v_tenant_id)
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A new invitation supersedes any prior outstanding (unaccepted) one for
  -- the same email in this tenant, per FR-A07's acceptance criteria.
  delete from public.tenant_invitation
   where tenant_id = v_tenant_id and email = p_email and accepted_at is null;

  insert into public.tenant_invitation (tenant_id, email, app_role, campus_ids, invited_by)
  values (v_tenant_id, p_email, p_role, p_campus_ids, v_inviter)
  returning id into v_invite_id;

  return v_invite_id;
end;
$$;

create or replace function public.accept_invitation(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite  record;
  v_uid     uuid := (select auth.uid());
  v_email   public.citext;
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;

  select * into v_invite from public.tenant_invitation where token = p_token;
  if not found then
    raise exception 'INVITE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_invite.accepted_at is not null then
    raise exception 'INVITE_ALREADY_USED' using errcode = '55000';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'INVITE_EXPIRED' using errcode = '55000';
  end if;

  select email into v_email from auth.users where id = v_uid;
  if v_email is distinct from v_invite.email then
    raise exception 'INVITE_EMAIL_MISMATCH' using errcode = '55000';
  end if;

  -- Parents and students are never staff accounts; they come from guardian activation and the
  -- student portal. An invitation for one of those roles is not valid.
  if v_invite.app_role::text in ('parent', 'student') then
    raise exception 'INVITE_ROLE_INVALID' using errcode = '55000';
  end if;

  if exists (select 1 from public.app_user where user_id = v_uid) then
    raise exception 'ALREADY_A_MEMBER' using errcode = '55000';
  end if;

  insert into public.app_user (user_id, tenant_id, app_role, full_name)
  values (v_uid, v_invite.tenant_id, v_invite.app_role, coalesce(v_email::text, 'New user'));

  if v_invite.campus_ids <> '{}' then
    insert into public.user_campus (user_id, tenant_id, campus_id)
    select v_uid, v_invite.tenant_id, c.id from unnest(v_invite.campus_ids) c(id);
  end if;

  update public.tenant_invitation
     set accepted_at = now(), accepted_user_id = v_uid
   where id = v_invite.id;

  return v_invite.tenant_id;
end;
$$;

create or replace function public.assign_custom_role(
  p_user_id uuid,
  p_role_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_caller_role text := app.auth_role();
  v_target_role text;
begin
  if v_tenant_id is null or not app.has_permission('role.manage') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_role_id is not null then
    perform app.assert_custom_role_writable(p_role_id);
    perform app.assert_permission_superset(app.role_permission_codes(p_role_id));
  end if;

  -- A custom role narrows what its holder can do, so it can only be put on someone ranked below the
  -- person doing it. Without this a Principal could strip an Owner to nothing, and the Owner could
  -- not undo it because clearing the role needs the permission that was just removed.
  select au.app_role::text into v_target_role
    from public.app_user au
   where au.user_id = p_user_id and au.tenant_id = v_tenant_id;
  if v_target_role is not null and v_caller_role <> 'super_admin'
     and app.fn_role_rank(v_caller_role) <= app.fn_role_rank(v_target_role) then
    raise exception 'FORBIDDEN' using errcode = '42501',
      detail = 'a custom role can only be assigned to someone ranked below you';
  end if;

  update public.app_user
     set custom_role_id = p_role_id
   where user_id = p_user_id
     and tenant_id = v_tenant_id;

  if not found then
    raise exception 'USER_NOT_FOUND' using errcode = '42501';
  end if;
end;
$$;

-- ── role and role_permission: written only through the functions ────────────

drop policy if exists role_write_requires_role_manage on public.role;
drop policy if exists role_permission_write_requires_role_manage on public.role_permission;
