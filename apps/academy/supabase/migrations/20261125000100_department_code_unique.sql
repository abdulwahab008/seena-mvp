-- Creating a department with a code already in use silently renamed the
-- existing department (insert ... on conflict do update) while the screen said
-- "created". A used code is now refused, on create and on edit.

create or replace function public.upsert_department(
  p_code text,
  p_name_en text,
  p_name_ur text default null,
  p_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_dept_id   uuid;
  v_code      text := upper(trim(p_code));
  v_name_en   text := trim(p_name_en);
  v_name_ur   text := nullif(trim(p_name_ur), '');
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_code = '' or v_name_en = '' then
    raise exception 'VALIDATION_ERROR' using detail = 'Department code and English name are required.';
  end if;

  if exists (select 1 from public.department where tenant_id = v_tenant_id and code = v_code and id is distinct from p_id) then
    raise exception 'DEPARTMENT_CODE_EXISTS' using errcode = '23505';
  end if;

  if p_id is not null then
    update public.department
       set code = v_code,
           name_en = v_name_en,
           name_ur = v_name_ur
     where id = p_id and tenant_id = v_tenant_id
    returning id into v_dept_id;

    if not found then
      raise exception 'DEPARTMENT_NOT_FOUND' using errcode = 'P0002';
    end if;
  else
    insert into public.department (tenant_id, code, name_en, name_ur)
    values (v_tenant_id, v_code, v_name_en, v_name_ur)
    returning id into v_dept_id;
  end if;

  return jsonb_build_object('id', v_dept_id, 'code', v_code, 'name_en', v_name_en, 'name_ur', v_name_ur);
end;
$$;
revoke execute on function public.upsert_department(text, text, text, uuid) from public, anon;
grant execute on function public.upsert_department(text, text, text, uuid) to authenticated;
