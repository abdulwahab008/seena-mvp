-- Audit BUG-04: the teacher a principal assigns as a section's class in-charge could neither save
-- that section's register nor request a correction unless their role was exactly class_teacher.
-- Schools assign subject teachers as in-charge (and the invite screen offered no Class Teacher
-- role at all), so the in-charge assignment for that date is now the authority, whatever the
-- teacher's role. Leadership roles keep their existing access.

CREATE OR REPLACE FUNCTION public.request_attendance_correction(p_enrolment_id uuid, p_attendance_date date, p_new_status student_attendance_status, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_enrol     public.enrolment%rowtype;
  v_day       public.attendance_day%rowtype;
  v_id        uuid;
begin
  select * into v_enrol from public.enrolment where id = p_enrolment_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    if not exists (
      select 1 from public.section_class_teacher
       where section_id = v_enrol.section_id and staff_id = auth.uid() and validity @> p_attendance_date
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('correction-pending:' || p_enrolment_id::text || ':' || p_attendance_date::text, 0));

  if exists (
    select 1 from public.attendance_correction_request
     where enrolment_id = p_enrolment_id and attendance_date = p_attendance_date and status = 'pending'
  ) then
    raise exception 'CORRECTION_ALREADY_PENDING' using errcode = '23514';
  end if;

  select * into v_day from public.attendance_day where enrolment_id = p_enrolment_id and attendance_date = p_attendance_date;

  insert into public.attendance_correction_request (
    tenant_id, campus_id, session_id, enrolment_id, attendance_date, old_status, new_status, reason, requested_by
  ) values (
    v_tenant_id, v_enrol.campus_id, v_enrol.session_id, p_enrolment_id, p_attendance_date, v_day.status, p_new_status, p_reason, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_attendance_register(p_section_id uuid, p_attendance_date date, p_marks jsonb, p_marked_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_source student_attendance_source DEFAULT 'web'::student_attendance_source, p_synced_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_section       public.class_section%rowtype;
  v_campus_tz     text;
  v_holiday       text;
  v_policy        jsonb;
  v_mark          record;
  v_arrival       time;
  v_marked_at     timestamptz := coalesce(p_marked_at, clock_timestamp());
  v_saved         int := 0;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    if not exists (
      select 1 from public.section_class_teacher
       where section_id = p_section_id and staff_id = auth.uid() and validity @> p_attendance_date
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  v_holiday := app.resolve_attendance_holiday_unscoped(v_section.tenant_id, v_section.campus_id, p_attendance_date);
  if v_holiday is not null then
    raise exception using message = 'HOLIDAY:' || v_holiday, errcode = '55000';
  end if;

  v_policy := app.resolve_attendance_policy_unscoped(v_section.tenant_id, v_section.campus_id, v_section.session_id);
  if v_policy is null then
    raise exception 'POLICY_NOT_CONFIGURED' using errcode = '55000';
  end if;

  if public.is_attendance_locked(p_section_id, p_attendance_date) then
    raise exception 'ATT_LOCKED' using errcode = '55000';
  end if;

  select timezone into v_campus_tz from public.campus where id = v_section.campus_id;

  for v_mark in
    select * from jsonb_to_recordset(p_marks)
      as m(enrolment_id uuid, status public.student_attendance_status, arrival_time time, departure_time time)
  loop
    if not exists (
      select 1 from public.enrolment e join public.student s on s.id = e.student_id
       where e.id = v_mark.enrolment_id and e.section_id = p_section_id and e.status = 'active' and s.status = 'active'
    ) then
      continue;
    end if;

    -- FR-G06: an unset arrival_time on a 'late' mark defaults to the
    -- campus wall-clock time the mark was CAPTURED at, not sync time —
    -- v_marked_at is now the honest source for both.
    v_arrival := case
      when v_mark.status = 'late' and v_mark.arrival_time is null then (v_marked_at at time zone v_campus_tz)::time
      else v_mark.arrival_time
    end;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by,
      marked_at, source, synced_at, arrival_time, departure_time
    ) values (
      v_tenant_id, v_section.campus_id, v_section.session_id, p_section_id, v_mark.enrolment_id, p_attendance_date, v_mark.status, auth.uid(),
      v_marked_at, p_source, p_synced_at, v_arrival, v_mark.departure_time
    )
    on conflict (enrolment_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by, marked_at = excluded.marked_at,
          source = excluded.source, synced_at = excluded.synced_at,
          arrival_time = excluded.arrival_time, departure_time = excluded.departure_time;

    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('saved', v_saved);
end;
$function$;
