-- FR-N12: English and Urdu language toggle.
--
-- The preference belongs to the PERSON (guardian / student portal account),
-- not the device, so it follows them across logins. Parents and students have
-- no UPDATE policy on those tables; the only write path is
-- set_preferred_language(), which can touch nothing but this column.
-- Numerals stay Latin in both languages (challan numbers, CNIC digits and
-- amounts are read off paper by bank tellers) — enforced in the app's locale
-- files and formatters, asserted by a test there.

alter table public.guardian
  add column if not exists preferred_language text not null default 'en' check (preferred_language in ('en', 'ur'));
alter table public.student_portal_account
  add column if not exists preferred_language text not null default 'en' check (preferred_language in ('en', 'ur'));

create or replace function public.get_preferred_language()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select g.preferred_language from public.guardian g where g.auth_user_id = (select auth.uid())),
    (select a.preferred_language from public.student_portal_account a where a.user_id = (select auth.uid()) and a.status = 'active'),
    'en'
  );
$$;
revoke execute on function public.get_preferred_language() from public, anon;
grant execute on function public.get_preferred_language() to authenticated;

create or replace function public.set_preferred_language(p_lang text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if p_lang is null or p_lang not in ('en', 'ur') then
    raise exception 'LANGUAGE_NOT_SUPPORTED' using errcode = '22023';
  end if;

  update public.guardian set preferred_language = p_lang where auth_user_id = v_uid;
  if found then
    return p_lang;
  end if;
  update public.student_portal_account set preferred_language = p_lang where user_id = v_uid and status = 'active';
  if found then
    return p_lang;
  end if;
  raise exception 'NO_PORTAL_PROFILE' using errcode = 'P0002';
end;
$$;
revoke execute on function public.set_preferred_language(text) from public, anon;
grant execute on function public.set_preferred_language(text) to authenticated;

-- FR-M04 template selection for a specific guardian: body_ur when they prefer
-- Urdu and the template has one, otherwise English. Message senders call this
-- (service role or staff); a parent has no business picking for another.
create or replace function public.pick_body_for_guardian(p_version_id uuid, p_guardian_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_lang text;
begin
  if app.auth_role() is not null and app.auth_role() in ('parent', 'student') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select g.preferred_language into v_lang
    from public.guardian g
    join public.message_template_version v on v.id = p_version_id
    join public.message_template t on t.id = v.template_id
   where g.id = p_guardian_id and g.tenant_id = t.tenant_id
     and (app.auth_tenant_id() is null or g.tenant_id = app.auth_tenant_id());
  if v_lang is null then
    raise exception 'GUARDIAN_OR_TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;

  return public.pick_body(p_version_id, v_lang);
end;
$$;
revoke execute on function public.pick_body_for_guardian(uuid, uuid) from public, anon;
grant execute on function public.pick_body_for_guardian(uuid, uuid) to authenticated, service_role;
