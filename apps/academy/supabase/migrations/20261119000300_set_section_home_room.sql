-- The rooms batch generator set class_section.home_room_id with a plain UPDATE, but class_section
-- has only a SELECT policy, so RLS silently discarded it and "auto-link as homeroom" never worked.
-- Setting a section's homeroom now goes through this function, with the same roles that create
-- sections and the same campus scope.
create or replace function public.set_section_home_room(p_section_id uuid, p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus_id from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);
  if p_room_id is not null
     and not exists (select 1 from public.room where id = p_room_id and campus_id = v_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'ROOM_NOT_IN_CAMPUS' using errcode = '23514';
  end if;
  update public.class_section set home_room_id = p_room_id where id = p_section_id;
end;
$$;

revoke execute on function public.set_section_home_room(uuid, uuid) from public, anon;
grant execute on function public.set_section_home_room(uuid, uuid) to authenticated;
