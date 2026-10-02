-- Migration: Comprehensive Staff & Teacher Registration
-- Enables creating full HR staff records with CNIC, contact info, employee code generation,
-- and automated portal invitations.

create or replace function public.register_staff_member(
  p_campus_id         uuid,
  p_full_name         text,
  p_gender            public.gender,
  p_id_document_type  public.id_document_type default 'cnic',
  p_cnic              text default null,
  p_passport_no       text default null,
  p_full_name_ur      text default null,
  p_contract_type     text default 'permanent',
  p_dob               date default null,
  p_doj               date default current_date,
  p_mobile            text default null,
  p_alt_mobile        text default null,
  p_address           text default null,
  p_emergency_contact text default null,
  p_role              public.app_role default 'subject_teacher',
  p_email             public.citext default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id        uuid := app.auth_tenant_id();
  v_normalized_cnic  text;
  v_existing_code    text;
  v_employee_code    text;
  v_staff_id         uuid;
  v_invite_id        uuid := null;
  v_user_id          uuid := null;
begin
  if v_tenant_id is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Verify and normalize identification document
  if p_id_document_type = 'cnic' then
    if p_cnic is null or trim(p_cnic) = '' then
      raise exception 'CNIC_REQUIRED' using errcode = '23514';
    end if;
    v_normalized_cnic := app.fn_normalize_pk_id(p_cnic);

    select employee_code into v_existing_code
      from public.staff
     where tenant_id = v_tenant_id and cnic = v_normalized_cnic and employment_status = 'active'
     limit 1;
    if found then
      raise exception 'CNIC_CONFLICT' using errcode = '23505',
        detail = format('A staff member with this CNIC already exists with employee code %s', v_existing_code);
    end if;
  elsif p_passport_no is null or trim(p_passport_no) = '' then
    raise exception 'PASSPORT_REQUIRED' using errcode = '23514';
  end if;

  v_employee_code := app.fn_next_employee_code(p_campus_id);

  -- Insert into staff
  insert into public.staff (
    tenant_id, campus_id, employee_code, id_document_type, cnic, passport_no,
    gender, contract_type, dob, doj, full_name, full_name_ur
  ) values (
    v_tenant_id, p_campus_id, v_employee_code, p_id_document_type, v_normalized_cnic, p_passport_no,
    p_gender, coalesce(nullif(trim(p_contract_type), ''), 'permanent'), p_dob, coalesce(p_doj, current_date),
    trim(p_full_name), nullif(trim(p_full_name_ur), '')
  )
  returning id into v_staff_id;

  -- Link staff to campus
  insert into public.staff_campus (staff_id, campus_id)
  values (v_staff_id, p_campus_id)
  on conflict do nothing;

  -- Insert private contact details if provided
  if p_mobile is not null or p_address is not null or p_emergency_contact is not null or p_alt_mobile is not null then
    insert into public.staff_private_contact (
      staff_id, mobile, alt_mobile, address, emergency_contact
    ) values (
      v_staff_id,
      nullif(trim(p_mobile), ''),
      nullif(trim(p_alt_mobile), ''),
      nullif(trim(p_address), ''),
      nullif(trim(p_emergency_contact), '')
    )
    on conflict (staff_id) do update set
      mobile = excluded.mobile,
      alt_mobile = excluded.alt_mobile,
      address = excluded.address,
      emergency_contact = excluded.emergency_contact,
      updated_at = now();
  end if;

  -- If email provided, issue portal invitation or link existing account
  if p_email is not null and trim(p_email::text) <> '' then
    -- Check if user already exists in auth.users
    select u.id into v_user_id
      from auth.users u
     where lower(u.email) = lower(trim(p_email::text));

    if v_user_id is not null then
      update public.staff set user_id = v_user_id where id = v_staff_id;
    else
      -- Dispatch invitation
      v_invite_id := public.invite_user(p_email, p_role, array[p_campus_id]);
    end if;
  end if;

  return jsonb_build_object(
    'staff_id', v_staff_id,
    'employee_code', v_employee_code,
    'full_name', trim(p_full_name),
    'invitation_id', v_invite_id
  );
end;
$$;

revoke execute on function public.register_staff_member(uuid, text, public.gender, public.id_document_type, text, text, text, text, date, date, text, text, text, text, public.app_role, public.citext) from public, anon;
grant execute on function public.register_staff_member(uuid, text, public.gender, public.id_document_type, text, text, text, text, date, date, text, text, text, text, public.app_role, public.citext) to authenticated;
