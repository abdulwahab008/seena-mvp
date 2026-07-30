-- FR-A02: an Owner/Super Admin creates additional campuses under their
-- tenant (provision_tenant only ever seeds the first one).

create or replace function public.create_campus(
  p_code text,
  p_name text,
  p_city text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_active_count int;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select count(*) into v_active_count
    from public.campus
   where tenant_id = v_tenant_id and status = 'active';
  if v_active_count >= 50 then
    raise exception 'CAMPUS_LIMIT_REACHED' using errcode = '54000';
  end if;

  if exists (
    select 1 from public.campus
     where tenant_id = v_tenant_id and upper(code) = upper(p_code)
  ) then
    raise exception 'CAMPUS_CODE_TAKEN' using errcode = '23505';
  end if;

  insert into public.campus (tenant_id, code, name, city)
  values (v_tenant_id, p_code, p_name, p_city)
  returning id into v_campus_id;

  return v_campus_id;
end;
$$;

revoke execute on function public.create_campus(text, text, text) from public, anon;
grant execute on function public.create_campus(text, text, text) to authenticated;
