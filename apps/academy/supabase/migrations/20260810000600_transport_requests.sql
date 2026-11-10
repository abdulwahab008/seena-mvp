-- A parent asks from the portal for the school bus to start, stop, or change
-- route or stop for their child; the transport office approves or rejects it.
-- Approval records the decision only: the office then makes the change under
-- Student Allocation, where seats, fares and fees are handled.

create table public.transport_request (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  student_id    uuid not null references public.student(id) on delete cascade,
  kind          text not null check (kind in ('start', 'stop', 'change_route', 'change_stop')),
  route_id      uuid references public.transport_route(id) on delete set null,
  note          text check (note is null or length(note) <= 300),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  requested_by  uuid default auth.uid() references auth.users(id),
  decided_by    uuid references auth.users(id),
  decided_at    timestamptz,
  decision_note text check (decision_note is null or length(decision_note) <= 300),
  created_at    timestamptz not null default now()
);
create index idx_transport_request_scope on public.transport_request (tenant_id, campus_id, status, created_at desc);
create index idx_transport_request_student on public.transport_request (student_id);
create index idx_transport_request_route on public.transport_request (route_id);

create trigger transport_request_audit after insert or update or delete on public.transport_request
  for each row execute function app.tg_audit_row();

alter table public.transport_request enable row level security;
create policy transport_request_staff_read on public.transport_request for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy transport_request_parent_read on public.transport_request for select to authenticated
  using (tenant_id = app.auth_tenant_id() and student_id = any (app.auth_guardian_student_ids()));

-- Parents read their own requests, so the table joins the portal list and only its writes are
-- closed to the portal roles (the submit function is how a parent writes).
create or replace function app.fn_portal_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array[
      -- the portal's own reads (pages, views, embedded relations, download routes and the tables
      -- their policies and storage policies look at), and every table that has a policy for
      -- guardians or students of its own: those policies decide what a parent or student sees
      'academic_session', 'academic_term', 'annual_result', 'app_user', 'attendance_day',
      'bell_calendar_rule', 'bell_template', 'branding_asset', 'campus', 'campus_branding', 'campus_event',
      'campus_event_override', 'campus_portal_policy', 'certificate_issue', 'certificate_request',
      'certificate_request_purpose', 'challan_template', 'circular', 'circular_attachment',
      'circular_read_receipt', 'class_level', 'class_section', 'class_subject', 'consent_purpose',
      'consent_record', 'consent_text_version', 'datesheet_slot_snapshot', 'datesheet_version', 'enrolment',
      'exam_subject', 'exam_term', 'feature_flag', 'fee_challan', 'fee_challan_line', 'fee_head',
      'fee_structure', 'grading_band', 'grading_scheme', 'guardian', 'holiday_calendar', 'homework',
      'homework_attachment', 'homework_feedback_history', 'homework_submission', 'homework_submission_file',
      'homework_submission_version', 'hostel_allocation', 'hostel_gate_pass', 'hostel_mess_menu',
      'hostel_mess_off', 'hostel_security_deposit', 'house', 'house_point', 'house_setting', 'inv_sale',
      'inv_student_entitlement', 'library_copy', 'library_fine', 'library_loan', 'library_reservation',
      'library_title', 'library_write_off', 'payment_gateway_config', 'payment_intent', 'permission', 'plan',
      'plan_feature', 'ptm_booking', 'ptm_event', 'ptm_waitlist', 'question_response_mark', 'report_card',
      'report_card_batch', 'report_card_packet', 'result_position', 'result_withhold', 'room', 'stream',
      'student', 'student_guardian', 'student_house_history', 'student_leave_application',
      'student_leave_attachment', 'student_portal_account', 'student_remark', 'student_remark_version',
      'subject', 'subject_result', 'support_ticket', 'tax_slab', 'tax_slab_version', 'tenant',
      'tenant_feature_override', 'tenant_setting', 'tenant_theme', 'term_remark', 'ticket_attachment',
      'ticket_message', 'timetable_slot', 'timetable_version', 'transcript_issue', 'transport_allocation',
      'transport_boarding_event', 'transport_fare_slab', 'transport_route', 'transport_stop',
      'transport_request', 'transport_trip_leg', 'transport_vehicle_position_latest'
  ]::text[];
$$;
select app.fn_restrict_portal_writes('public.transport_request');

create or replace function public.submit_transport_request(p_student_id uuid, p_kind text, p_route_id uuid default null, p_note text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stud public.student%rowtype;
  v_id uuid;
begin
  select * into v_stud from public.student
   where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null
     and id = any (app.auth_guardian_student_ids());
  if not found then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_kind not in ('start', 'stop', 'change_route', 'change_stop') then
    raise exception 'KIND_INVALID' using errcode = '22023';
  end if;
  if p_route_id is not null and not exists (select 1 from public.transport_route where id = p_route_id and tenant_id = v_stud.tenant_id) then
    raise exception 'ROUTE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.transport_request where student_id = p_student_id and status = 'pending') then
    raise exception 'REQUEST_PENDING' using errcode = '23505';
  end if;
  insert into public.transport_request (tenant_id, campus_id, student_id, kind, route_id, note)
  values (v_stud.tenant_id, v_stud.campus_id, p_student_id, p_kind, p_route_id, nullif(btrim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.submit_transport_request(uuid, text, uuid, text) from public, anon;
grant execute on function public.submit_transport_request(uuid, text, uuid, text) to authenticated;

create or replace function public.decide_transport_request(p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_r public.transport_request%rowtype;
begin
  select * into v_r from public.transport_request where id = p_request_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_r.campus_id);
  if app.auth_role() not in ('owner', 'super_admin') and not (v_r.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_r.status <> 'pending' then
    raise exception 'REQUEST_NOT_PENDING' using errcode = '55000';
  end if;
  if p_note is not null and length(p_note) > 300 then
    raise exception 'NOTE_TOO_LONG' using errcode = '22001';
  end if;
  update public.transport_request
     set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = auth.uid(), decided_at = now(), decision_note = nullif(btrim(p_note), '')
   where id = p_request_id;
end;
$$;
revoke execute on function public.decide_transport_request(uuid, boolean, text) from public, anon;
grant execute on function public.decide_transport_request(uuid, boolean, text) to authenticated;
