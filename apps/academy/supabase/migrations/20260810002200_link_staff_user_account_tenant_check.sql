-- link_staff_user_account() trusted p_user_id as given, so a caller could attach any auth user, even one
-- from another school, to a staff record, and one login could end up on two staff records. The login must
-- now be an active user of the same school and not already on another staff record. Passing null unlinks.
create or replace function public.link_staff_user_account(p_staff_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_user_id is not null then
    if not exists (select 1 from public.app_user where user_id = p_user_id and tenant_id = v_tenant_id and status = 'active') then
      raise exception 'USER_NOT_FOUND' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.staff where user_id = p_user_id and id <> p_staff_id) then
      raise exception 'USER_ALREADY_LINKED' using errcode = '23505';
    end if;
  end if;

  update public.staff set user_id = p_user_id where id = p_staff_id;
end;
$$;

revoke execute on function public.link_staff_user_account(uuid, uuid) from public, anon;
grant execute on function public.link_staff_user_account(uuid, uuid) to authenticated;
