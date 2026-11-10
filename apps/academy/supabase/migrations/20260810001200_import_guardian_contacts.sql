-- Bulk-link fathers to students who already exist. The student import carries only the father's name, so a
-- school that imported its register has no guardian records: no parent portal, no fee notices or absence SMS,
-- and no sibling detection (which matches siblings by the father's CNIC). This takes rows of
-- {row, gr_number, father_name?, father_cnic?, father_phone?} and, per row, reuses the guardian with that CNIC
-- or creates one, then links them to the student as father (primary and fee contact when none exists yet).
-- Each row succeeds or fails on its own; the result lists the failures.
create or replace function public.import_guardian_contacts(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_row         jsonb;
  v_student     public.student%rowtype;
  v_cnic        text;
  v_digits      text;
  v_phone       text;
  v_name        text;
  v_guardian_id uuid;
  v_linked      int := 0;
  v_errors      jsonb := '[]'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then
    raise exception 'ROWS_INVALID' using errcode = '22023';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    begin
      select * into v_student from public.student
       where tenant_id = v_tenant_id and gr_number = btrim(v_row ->> 'gr_number') and deleted_at is null;
      if not found or (app.auth_role() not in ('super_admin', 'owner') and not (v_student.campus_id = any(app.auth_campus_ids()))) then
        raise exception 'No student has this GR number.';
      end if;
      if exists (select 1 from public.student_guardian where student_id = v_student.id and relationship = 'father' and to_date is null) then
        raise exception 'This student already has a father linked.';
      end if;

      v_cnic := nullif(btrim(coalesce(v_row ->> 'father_cnic', '')), '');
      if v_cnic is not null and length(regexp_replace(v_cnic, '[^0-9]', '', 'g')) <> 13 then
        raise exception 'The father''s CNIC must have 13 digits.';
      end if;
      v_cnic := app.fn_normalize_pk_id(v_cnic);

      v_digits := regexp_replace(coalesce(v_row ->> 'father_phone', ''), '[^0-9]', '', 'g');
      v_phone := case
        when v_digits = '' then null
        when v_digits ~ '^923[0-9]{9}$' then '+' || v_digits
        when v_digits ~ '^03[0-9]{9}$' then '+92' || substr(v_digits, 2)
        when v_digits ~ '^3[0-9]{9}$' then '+92' || v_digits
      end;
      if v_digits <> '' and v_phone is null then
        raise exception 'The father''s phone must be a Pakistani mobile number, e.g. 0300 1234567.';
      end if;
      if v_cnic is null and v_phone is null then
        raise exception 'Give the father''s CNIC or phone number.';
      end if;

      v_name := coalesce(nullif(btrim(coalesce(v_row ->> 'father_name', '')), ''), nullif(btrim(coalesce(v_student.father_name_en, '')), ''));
      if v_name is null then
        raise exception 'Give the father''s name.';
      end if;

      v_guardian_id := null;
      if v_cnic is not null then
        select id into v_guardian_id from public.guardian where tenant_id = v_tenant_id and cnic = v_cnic;
      end if;
      if v_guardian_id is null then
        insert into public.guardian (tenant_id, cnic, name_en, phone_e164)
        values (v_tenant_id, v_cnic, v_name, v_phone)
        returning id into v_guardian_id;
      elsif v_phone is not null then
        update public.guardian set phone_e164 = coalesce(phone_e164, v_phone) where id = v_guardian_id;
      end if;

      insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
      values (
        v_tenant_id, v_student.id, v_guardian_id, 'father',
        not exists (select 1 from public.student_guardian where student_id = v_student.id and is_primary and to_date is null),
        true
      );
      v_linked := v_linked + 1;
    exception when others then
      v_errors := v_errors || jsonb_build_object('row', v_row -> 'row', 'gr_number', v_row ->> 'gr_number', 'message', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('linked', v_linked, 'failed', jsonb_array_length(v_errors), 'errors', v_errors);
end;
$$;

revoke execute on function public.import_guardian_contacts(jsonb) from public, anon;
grant execute on function public.import_guardian_contacts(jsonb) to authenticated;
