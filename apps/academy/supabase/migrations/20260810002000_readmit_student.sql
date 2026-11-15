-- Readmitting a student who left. The old fn_readmit_student always inserted a new enrolment, so
-- a student withdrawn mid-session and readmitted in that same session hit enrolment's one-per-
-- session unique key. Now that session's closed enrolment is reopened into the chosen section
-- instead; any other session still gets a fresh enrolment. It also checks the campus.
create or replace function public.fn_readmit_student(p_student_id uuid, p_section_id uuid, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student      public.student%rowtype;
  v_section      public.class_section%rowtype;
  v_enrolment_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_student from public.student where id = p_student_id and deleted_at is null;
  if not found or v_student.tenant_id <> app.auth_tenant_id() then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_student.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_section from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found or v_section.campus_id <> v_student.campus_id then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_student.no_readmission_flag then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'READMISSION_BLOCKED'
        using errcode = '42501', detail = 'flagged no_readmission — only an Owner/Director may override, with a recorded reason';
    end if;
    if nullif(btrim(p_override_reason), '') is null then
      raise exception 'OVERRIDE_REASON_REQUIRED' using errcode = '23514';
    end if;
  end if;

  perform public.fn_change_student_status(
    p_student_id, 'active', 'readmission', app.fn_karachi_today(),
    case when v_student.no_readmission_flag then p_override_reason || ' [no_readmission override]' else p_override_reason end
  );

  select id into v_enrolment_id from public.enrolment
   where student_id = p_student_id and session_id = v_section.session_id and deleted_at is null;

  if v_enrolment_id is null then
    v_enrolment_id := public.enrol_student(p_section_id, p_student_id);
  else
    update public.enrolment
       set status = 'active', section_id = p_section_id, class_level_id = v_section.class_level_id,
           left_on = null, tc_issued_at = null, tc_certificate_issue_id = null,
           -- keep the old roll number only if it is still free in the section the student returns to
           roll_no = case
             when e.section_id = p_section_id and not exists (
               select 1 from public.enrolment o where o.section_id = p_section_id and o.roll_no = e.roll_no and o.id <> e.id)
             then e.roll_no
             else (select coalesce(max(o.roll_no), 0) + 1 from public.enrolment o where o.section_id = p_section_id)
           end
      from public.enrolment e
     where public.enrolment.id = v_enrolment_id and e.id = v_enrolment_id;
    insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
    values (v_enrolment_id, p_section_id, app.fn_karachi_today(), auth.uid(), 'readmission');
  end if;

  return v_enrolment_id;
end;
$$;
