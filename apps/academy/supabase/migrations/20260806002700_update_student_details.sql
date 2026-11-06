-- Audit: a student's name, date of birth, gender, father's name and B-Form could be entered at
-- admission but never corrected; the profile offered only Delete. The roles that may admit a
-- student may now correct these details. The GR number is permanent and is not editable.
create or replace function public.update_student_details(
  p_student_id uuid, p_name_en text, p_dob date, p_gender public.gender,
  p_name_ur text default null, p_father_name_en text default null, p_father_name_ur text default null, p_b_form_no text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student public.student%rowtype;
  v_bform   text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_student from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_student.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if nullif(btrim(p_name_en), '') is null then
    raise exception 'NAME_REQUIRED' using errcode = '22023';
  end if;

  if p_b_form_no is not null and btrim(p_b_form_no) <> '' then
    v_bform := regexp_replace(p_b_form_no, '[^0-9]', '', 'g');
    if length(v_bform) <> 13 then
      raise exception 'BFORM_INVALID_FORMAT' using errcode = '23514';
    end if;
    v_bform := substr(v_bform, 1, 5) || '-' || substr(v_bform, 6, 7) || '-' || substr(v_bform, 13, 1);
    if exists (select 1 from public.student where tenant_id = app.auth_tenant_id() and b_form_no = v_bform and id <> p_student_id) then
      raise exception 'BFORM_DUPLICATE' using errcode = '23505';
    end if;
  end if;

  update public.student
     set name_en = btrim(p_name_en), name_ur = nullif(btrim(p_name_ur), ''), dob = p_dob, gender = p_gender,
         father_name_en = nullif(btrim(p_father_name_en), ''), father_name_ur = nullif(btrim(p_father_name_ur), ''),
         b_form_no = v_bform
   where id = p_student_id;
end;
$$;

revoke execute on function public.update_student_details(uuid, text, date, public.gender, text, text, text, text) from public, anon;
grant execute on function public.update_student_details(uuid, text, date, public.gender, text, text, text, text) to authenticated;
