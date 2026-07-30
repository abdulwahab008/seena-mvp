-- FR-A07: staff invitation + acceptance flow. Closes the gap the
-- foundation migration deliberately left open ("the send-email /
-- accept-and-create-app_user flow is out of scope for this migration").

alter table public.tenant_invitation
  add column campus_ids uuid[] not null default '{}';

-- RLS is already enabled on tenant_invitation, and the admin-read policy
-- already exists, both from the foundation migration — nothing to add here.

-- ── invite_user (create + auto-invalidate prior outstanding invites) ─────

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

revoke execute on function public.invite_user(public.citext, public.app_role, uuid[]) from public, anon;
grant execute on function public.invite_user(public.citext, public.app_role, uuid[]) to authenticated;

-- ── get_invitation_preview (public: the token itself is the secret) ──────
-- Callable by anon — the invitee has no session yet when they open the
-- invite link. Returns just enough to render "join <school> as <role>"
-- before they create an account; never the tenant's internal id in a form
-- that lets them guess other tenants' data.

create or replace function public.get_invitation_preview(p_token text)
returns table (tenant_name text, email public.citext, app_role public.app_role, valid boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select t.name,
         i.email,
         i.app_role,
         (i.accepted_at is null and i.expires_at > now()) as valid
    from public.tenant_invitation i
    join public.tenant t on t.id = i.tenant_id
   where i.token = p_token;
$$;

revoke execute on function public.get_invitation_preview(text) from public;
grant execute on function public.get_invitation_preview(text) to anon, authenticated;

-- ── accept_invitation ──────────────────────────────────────────────────
-- Runs as the just-signed-up user (auth.uid() is their own new id). Binds
-- them to the inviting tenant; does not touch anyone else's account.

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

revoke execute on function public.accept_invitation(text) from public, anon;
grant execute on function public.accept_invitation(text) to authenticated;
