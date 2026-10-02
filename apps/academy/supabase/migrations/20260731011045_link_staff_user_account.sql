-- Small enabling piece, not its own FR: FR-D01 made staff.user_id
-- nullable ("HR can enter a staff record before any login exists") but
-- never built the other half — a way to connect it once a login DOES
-- exist. Without this, every "the logged-in user's own staff record"
-- lookup used throughout FR-D10/D11/D12/C05's RLS policies can never
-- match anyone, since no staff row's user_id is ever set.
create or replace function public.link_staff_user_account(p_staff_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff where id = p_staff_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.staff set user_id = p_user_id where id = p_staff_id;
end;
$$;

revoke execute on function public.link_staff_user_account(uuid, uuid) from public, anon;
grant execute on function public.link_staff_user_account(uuid, uuid) to authenticated;
