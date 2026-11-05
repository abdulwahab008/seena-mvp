-- Audit: a campus could be added and archived but never corrected or brought back, and the setup
-- checklist asks the owner to "confirm" a name and code nothing could change. Owners can now
-- edit a campus and restore an archived one, and the last active campus cannot be archived.
-- Restoring does not re-grant staff access: archiving switched it off, and who should get it
-- back is a decision for the owner, made on the staff screens.

create or replace function public.update_campus(p_campus_id uuid, p_code text, p_name text, p_city text default null)
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
  if nullif(btrim(p_name), '') is null or length(btrim(coalesce(p_code, ''))) < 2 then
    raise exception 'CAMPUS_INVALID' using errcode = '22023';
  end if;
  if exists (select 1 from public.campus where tenant_id = v_tenant_id and upper(code) = upper(btrim(p_code)) and id <> p_campus_id) then
    raise exception 'CAMPUS_CODE_TAKEN' using errcode = '23505';
  end if;

  update public.campus
     set code = upper(btrim(p_code)), name = btrim(p_name), city = nullif(btrim(p_city), '')
   where id = p_campus_id;
end;
$$;

create or replace function public.restore_campus(p_campus_id uuid)
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
  update public.campus set status = 'active', deleted_at = null where id = p_campus_id;
end;
$$;

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
  if not exists (select 1 from public.campus where tenant_id = v_tenant_id and status = 'active' and id <> p_campus_id) then
    raise exception 'LAST_ACTIVE_CAMPUS' using errcode = '55000';
  end if;

  update public.campus set status = 'archived', deleted_at = now() where id = p_campus_id;
  update public.user_campus set is_active = false where campus_id = p_campus_id;
end;
$$;

revoke execute on function public.update_campus(uuid, text, text, text) from public, anon;
revoke execute on function public.restore_campus(uuid) from public, anon;
grant execute on function public.update_campus(uuid, text, text, text) to authenticated;
grant execute on function public.restore_campus(uuid) to authenticated;
