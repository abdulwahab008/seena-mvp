-- Audit BUG-18: a member's name was always their email address, even when they gave their full
-- name at sign-up or on the invitation page. Use that name when there is one.
CREATE OR REPLACE FUNCTION public.accept_invitation(p_token text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  values (v_uid, v_invite.tenant_id, v_invite.app_role,
          coalesce(nullif(btrim((select raw_user_meta_data ->> 'full_name' from auth.users where id = v_uid)), ''), v_email::text, 'New user'));

  if v_invite.campus_ids <> '{}' then
    insert into public.user_campus (user_id, tenant_id, campus_id)
    select v_uid, v_invite.tenant_id, c.id from unnest(v_invite.campus_ids) c(id);
  end if;

  update public.tenant_invitation
     set accepted_at = now(), accepted_user_id = v_uid
   where id = v_invite.id;

  return v_invite.tenant_id;
end;
$function$;

update public.app_user au
   set full_name = btrim(u.raw_user_meta_data ->> 'full_name')
  from auth.users u
 where u.id = au.user_id
   and au.full_name = u.email::text
   and nullif(btrim(u.raw_user_meta_data ->> 'full_name'), '') is not null;
