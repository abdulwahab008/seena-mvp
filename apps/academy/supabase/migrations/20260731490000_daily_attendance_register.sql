-- FR-G02: daily section attendance register.
--
--   * The lock check is a property of the DATE (via FR-G01's resolve_
--     attendance_policy().lock_window_hours), not of each individual
--     student row — every mark in one save_attendance_register() call
--     shares the same attendance_date, so it is checked once up front,
--     not per row. Deadline = end of that calendar day plus the
--     configured grace window, e.g. lock_window_hours=24 means edits
--     close at midnight the day after.
--   * "returns 409 if locked" (the AC's own words) is a raised
--     ATTENDANCE_LOCKED exception, not a literal HTTP route — this is a
--     Server Action/RPC call like every other mutation in this session,
--     not one of the handful of routes (FR-B02) built specifically
--     because the AC needed a real, literal status code with no session
--     involved. The upsert itself (ON CONFLICT DO UPDATE) is what makes
--     concurrent submissions from two devices safe without any extra
--     locking of our own — Postgres already serializes concurrent
--     writers on the same (enrolment_id, attendance_date) row.
--   * Holiday resolution reuses holiday_calendar verbatim (FR-D11) —
--     campus-specific rows win over a tenant-wide (campus_id is null)
--     row, the exact fallback semantics working_days_between() already
--     established for the same table.
--   * Write access is section_class_teacher-scoped (FR-E08): a
--     class_teacher may only save the register for a section they were
--     actually assigned to as of the attendance_date being marked, via
--     that table's own validity daterange — not just "any class_teacher
--     anywhere in the tenant."
--   * struck_off exclusion (AC2): the AC's own wording is "enrolment
--     status became struck_off," but enrolment_status (FR-C12) has no
--     such value — 'struck_off' lives on student.status. The candidate
--     check joins both (enrolment.status='active' and student.status=
--     'active'), the same two-table check generate_challans() (FR-K09)
--     already uses for the identical reason. A client-supplied mark for
--     a departed student is silently dropped, not an error — a stale
--     roster shouldn't hard-fail the whole register save.

create type public.student_attendance_status as enum ('present', 'absent', 'late', 'half_day', 'excused');
create type public.student_attendance_source as enum ('web', 'mobile', 'offline_sync', 'biometric');

create table public.attendance_day (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  section_id     uuid not null references public.class_section(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  attendance_date date not null,
  status         public.student_attendance_status not null,
  marked_by      uuid references public.app_user(user_id),
  marked_at      timestamptz not null default clock_timestamp(),
  source         public.student_attendance_source not null default 'web',
  constraint uq_attendance_day_enrolment_date unique (enrolment_id, attendance_date)
);

create index idx_att_day_section_date on public.attendance_day (campus_id, section_id, attendance_date);
create index idx_att_day_enrol_date on public.attendance_day (enrolment_id, attendance_date);

create trigger attendance_day_audit after insert or update or delete on public.attendance_day
  for each row execute function app.tg_audit_row();

create or replace function public.resolve_attendance_holiday(p_campus_id uuid, p_date date)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select name from public.holiday_calendar
   where tenant_id = app.auth_tenant_id() and (campus_id is null or campus_id = p_campus_id) and holiday_date = p_date
   order by campus_id nulls last
   limit 1;
$$;

revoke execute on function public.resolve_attendance_holiday(uuid, date) from public, anon;
grant execute on function public.resolve_attendance_holiday(uuid, date) to authenticated;

create or replace function public.save_attendance_register(p_section_id uuid, p_attendance_date date, p_marks jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_section       public.class_section%rowtype;
  v_holiday       text;
  v_policy        jsonb;
  v_lock_deadline timestamptz;
  v_mark          record;
  v_saved         int := 0;
begin
  select * into v_section from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    if app.auth_role() <> 'class_teacher' or not exists (
      select 1 from public.section_class_teacher
       where section_id = p_section_id and staff_id = auth.uid() and validity @> p_attendance_date
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- AC4: a holiday blocks the save just as it makes the screen
  -- read-only — checked here too, not just left to the client.
  v_holiday := public.resolve_attendance_holiday(v_section.campus_id, p_attendance_date);
  if v_holiday is not null then
    raise exception using message = 'HOLIDAY:' || v_holiday, errcode = '55000';
  end if;

  v_policy := public.resolve_attendance_policy(v_section.campus_id, v_section.session_id);
  if v_policy is null then
    raise exception 'POLICY_NOT_CONFIGURED' using errcode = '55000';
  end if;

  v_lock_deadline := (p_attendance_date + 1)::timestamptz + make_interval(hours => (v_policy ->> 'lock_window_hours')::int);
  if clock_timestamp() > v_lock_deadline then
    raise exception 'ATTENDANCE_LOCKED' using errcode = '55000';
  end if;

  for v_mark in select * from jsonb_to_recordset(p_marks) as m(enrolment_id uuid, status public.student_attendance_status)
  loop
    -- "struck-off" (AC2's own wording) lives on student.status, not
    -- enrolment.status — enrolment_status has no such value. Same
    -- both-must-be-active join as generate_challans() (FR-K09).
    if not exists (
      select 1 from public.enrolment e join public.student s on s.id = e.student_id
       where e.id = v_mark.enrolment_id and e.section_id = p_section_id and e.status = 'active' and s.status = 'active'
    ) then
      continue;
    end if;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by
    ) values (
      v_tenant_id, v_section.campus_id, v_section.session_id, p_section_id, v_mark.enrolment_id, p_attendance_date, v_mark.status, auth.uid()
    )
    on conflict (enrolment_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by, marked_at = clock_timestamp();

    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('saved', v_saved);
end;
$$;

revoke execute on function public.save_attendance_register(uuid, date, jsonb) from public, anon;
grant execute on function public.save_attendance_register(uuid, date, jsonb) to authenticated;

alter table public.attendance_day enable row level security;

create policy attendance_day_campus_read on public.attendance_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
