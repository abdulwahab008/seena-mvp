-- FR-G10: attendance correction request.
--
-- FR-G11's own migration (20260731520000) already built the request/
-- approve/reject pipeline this FR needs — request_attendance_correction()
-- already exists and is reused here, not rebuilt. This migration closes
-- the gap between that earlier build and FR-G10's own specific ACs: a
-- 15-character reason minimum (FR-G11 shipped with 10), and exactly one
-- pending request per (enrolment, date) — nothing in the earlier build
-- stopped a class teacher submitting the same correction five times.
--
-- FR-G10's own AC4 ("a correction request older than 30 days is rejected
-- unless the requester holds principal/owner") is deliberately NOT built:
-- FR-G11's entire premise — and its own already-shipped pgTAP and e2e
-- tests — is a class teacher requesting a correction on an OLD, already-
-- locked day (100 days back in the e2e spec, 40/41 days in pgTAP), with
-- only the APPROVAL step requiring a Principal. A blanket 30-day
-- submission cutoff for non-principal roles would silently break that
-- already-shipped, already-verified workflow — the two ACs are in direct
-- conflict, and the already-shipped, already-tested behavior wins.

alter table public.attendance_correction_request drop constraint chk_correction_reason_len;
alter table public.attendance_correction_request add constraint chk_correction_reason_len check (length(btrim(reason)) >= 15);

-- AC: "a correction is already pending for this date" — the unique
-- index is the defense-in-depth backstop; the function's own pre-check
-- below (serialized per (enrolment, date) by an advisory lock, same
-- pattern as TEACHER_CLASH/ROOM_CLASH) is what gives a named, friendly
-- error instead of a raw duplicate-key violation.
create unique index uq_pending_correction on public.attendance_correction_request (enrolment_id, attendance_date) where status = 'pending';

create or replace function public.request_attendance_correction(
  p_enrolment_id uuid, p_attendance_date date, p_new_status public.student_attendance_status, p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
    if app.auth_role() <> 'class_teacher' or not exists (
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
$$;

revoke execute on function public.request_attendance_correction(uuid, date, public.student_attendance_status, text) from public, anon;
grant execute on function public.request_attendance_correction(uuid, date, public.student_attendance_status, text) to authenticated;
