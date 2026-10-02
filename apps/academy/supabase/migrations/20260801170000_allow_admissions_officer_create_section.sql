-- Migration: Allow admissions_officer to create sections during admission intake
CREATE OR REPLACE FUNCTION public.create_section(
  p_campus_id uuid,
  p_session_id uuid,
  p_class_level_id uuid,
  p_name text,
  p_capacity integer,
  p_medium public.section_medium DEFAULT 'ENGLISH'::public.section_medium,
  p_shift public.section_shift DEFAULT 'MORNING'::public.section_shift,
  p_gender_restriction public.gender DEFAULT NULL::public.gender
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, app
AS $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.class_level where id = p_class_level_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_capacity < 1 or p_capacity > 200 then
    raise exception 'CAPACITY_OUT_OF_RANGE' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.class_section
     where campus_id = p_campus_id and session_id = p_session_id
       and class_level_id = p_class_level_id and name = p_name
  ) then
    raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end if;

  begin
    insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift, gender_restriction)
    values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_name, p_capacity, p_medium, p_shift, p_gender_restriction)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end;

  return v_id;
end;
$$;
