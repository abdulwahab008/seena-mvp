-- Migration: update_room RPC for modifying existing room details
-- Enables school administrators to update room code, name, type, capacity, and building block

create or replace function public.update_room(
  p_id uuid,
  p_code text,
  p_name text,
  p_room_type public.room_type_enum,
  p_capacity int,
  p_block_label text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, campus_id into v_tenant_id, v_campus_id
    from public.room
   where id = p_id;

  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ROOM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_capacity < 1 then
    raise exception 'CAPACITY_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  begin
    update public.room
       set code = trim(p_code),
           name = trim(p_name),
           room_type = p_room_type,
           capacity = p_capacity,
           block_label = nullif(trim(p_block_label), '')
     where id = p_id;
  exception
    when unique_violation then
      raise exception 'ROOM_CODE_DUPLICATE' using errcode = '23505';
  end;
end;
$$;

revoke execute on function public.update_room(uuid, text, text, public.room_type_enum, int, text) from public, anon;
grant execute on function public.update_room(uuid, text, text, public.room_type_enum, int, text) to authenticated;
