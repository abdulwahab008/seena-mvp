-- Accepting an invitation, and usernames for invited staff.
--
-- Production requires email confirmation, so the invite page's sign-up came
-- back without a session and accept_invitation() refused it. The invite page
-- now creates the account server-side as already confirmed (the invitation
-- link, sent to that address, is the proof). These helpers are for that
-- server-side step only: service_role, never the browser.
--
-- Invited staff may also choose a username and then sign in with
-- username@school-code, like accounts created directly by the school.

-- What the invite page needs before creating or reusing an account.
create or replace function public.invite_account_state(p_token text)
returns table (email text, valid boolean, tenant_id uuid, school_code text, user_id uuid, confirmed boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select i.email::text, (i.accepted_at is null and i.expires_at > now()), i.tenant_id, t.slug, u.id, u.email_confirmed_at is not null
    from public.tenant_invitation i
    join public.tenant t on t.id = i.tenant_id
    left join auth.users u on lower(u.email) = lower(i.email::text)
   where i.token = p_token;
$$;
revoke execute on function public.invite_account_state(text) from public, anon, authenticated;
grant execute on function public.invite_account_state(text) to service_role;

-- 'ok', 'invalid' or 'taken', for the school the invitation belongs to.
create or replace function public.invite_username_check(p_token text, p_username text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when lower(p_username) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then 'invalid'
           when exists (select 1 from public.app_user a where a.tenant_id = i.tenant_id and a.username = lower(p_username)::public.citext) then 'taken'
           else 'ok'
         end
    from public.tenant_invitation i
   where i.token = p_token;
$$;
revoke execute on function public.invite_username_check(text, text) from public, anon, authenticated;
grant execute on function public.invite_username_check(text, text) to service_role;

-- The signed-in member sets their own display name and, optionally, a username.
create or replace function public.update_my_profile(p_full_name text, p_username text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_tenant uuid;
  v_name   text := nullif(btrim(coalesce(p_full_name, '')), '');
  v_user   text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select tenant_id into v_tenant from public.app_user where user_id = v_uid;
  if v_uid is null or v_tenant is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_name is null or length(v_name) > 120 then
    raise exception 'NAME_REQUIRED' using errcode = '22023';
  end if;
  if v_user is not null then
    if v_user !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then
      raise exception 'USERNAME_INVALID' using errcode = '22023';
    end if;
    if exists (select 1 from public.app_user where tenant_id = v_tenant and username = v_user::public.citext and user_id <> v_uid) then
      raise exception 'USERNAME_TAKEN' using errcode = '23505';
    end if;
  end if;
  update public.app_user
     set full_name = v_name, username = coalesce(v_user::public.citext, username)
   where user_id = v_uid;
end;
$$;
revoke execute on function public.update_my_profile(text, text) from public, anon;
grant execute on function public.update_my_profile(text, text) to authenticated;

-- Sign-in by username@school-code for any member with a username, whatever
-- address their login uses. Only the server's sign-in action calls it.
create or replace function public.resolve_username_login(p_username text, p_school_code text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.email::text
    from public.tenant t
    join public.app_user a on a.tenant_id = t.id and a.username = lower(p_username)::public.citext
    join auth.users u on u.id = a.user_id
   where t.slug = lower(p_school_code) and t.status = 'active';
$$;
revoke execute on function public.resolve_username_login(text, text) from public, anon, authenticated;
grant execute on function public.resolve_username_login(text, text) to service_role;
