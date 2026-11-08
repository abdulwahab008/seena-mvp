-- Rename a class level (e.g. "Nursery" -> "Seena Junior"). Only the display
-- name changes: the code stays, because imports and reports match on it.
create or replace function public.rename_class_level(p_id uuid, p_name_en text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name_en, ''));
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_name = '' or length(v_name) > 60 then
    raise exception 'NAME_INVALID' using errcode = '22023';
  end if;

  update public.class_level
     set name_en = v_name
   where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.rename_class_level(uuid, text) from public, anon;
grant execute on function public.rename_class_level(uuid, text) to authenticated;
