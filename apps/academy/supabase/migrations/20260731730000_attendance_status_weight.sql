-- FR-G06: late and half-day status resolution.
--
--   * attendance_weight() is the single source of truth for "how much
--     does this status count toward present_days" — an unconfigured
--     (campus, session, status) falls back to the same weights FR-G14
--     already hardcoded (present=1, late=1, half_day=0.5, else 0), so
--     every existing tenant's math is unchanged until a Principal
--     explicitly arms an override. compute_month_attendance() is
--     redefined below to call it instead of its own inline case
--     expression — its store-once-then-upsert-on-recompute semantics
--     (unchanged from FR-G14) are what satisfies AC3: a weight change
--     only affects rows computed AFTER the change, since already-stored
--     attendance_month_summary rows are never touched by anything except
--     a fresh compute_month_attendance() call.
--   * arrival_time defaulting lives in save_attendance_register() (the
--     FR-G09 version, the only writer of attendance_day) — 'late' with
--     no arrival_time supplied gets the campus's own local wall-clock
--     time at save time. campus.timezone already exists (defaults to
--     'Asia/Karachi', same literal FR-G09 hardcodes for its lock-window
--     math) — joined here rather than hardcoded, a small correctness
--     improvement over FR-G09's own literal now that a per-row campus is
--     already in scope. AC4 (present + arrival_time stored, weight
--     unaffected) needs no special-case code: attendance_weight() keys
--     only on status, never on arrival_time.

create table public.attendance_status_weight (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  session_id  uuid not null references public.academic_session(id) on delete cascade,
  status      public.student_attendance_status not null,
  weight      numeric(3, 2) not null,
  created_at  timestamptz not null default now(),
  constraint chk_att_status_weight_range check (weight >= 0 and weight <= 1),
  unique (campus_id, session_id, status)
);

create trigger attendance_status_weight_audit after insert or update or delete on public.attendance_status_weight
  for each row execute function app.tg_audit_row();

alter table public.attendance_status_weight enable row level security;

create policy attendance_status_weight_read on public.attendance_status_weight
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create or replace function public.attendance_weight(p_status public.student_attendance_status, p_campus_id uuid, p_session_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select weight from public.attendance_status_weight
      where campus_id = p_campus_id and session_id = p_session_id and status = p_status),
    case p_status when 'present' then 1 when 'late' then 1 when 'half_day' then 0.5 else 0 end
  );
$$;

revoke execute on function public.attendance_weight(public.student_attendance_status, uuid, uuid) from public, anon;
grant execute on function public.attendance_weight(public.student_attendance_status, uuid, uuid) to authenticated, service_role;

create or replace function public.set_attendance_status_weight(
  p_campus_id uuid, p_session_id uuid, p_status public.student_attendance_status, p_weight numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_weight < 0 or p_weight > 1 then
    raise exception 'WEIGHT_OUT_OF_RANGE' using errcode = '23514';
  end if;

  insert into public.attendance_status_weight (tenant_id, campus_id, session_id, status, weight)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_status, p_weight)
  on conflict (campus_id, session_id, status) do update set weight = excluded.weight;
end;
$$;

revoke execute on function public.set_attendance_status_weight(uuid, uuid, public.student_attendance_status, numeric) from public, anon;
grant execute on function public.set_attendance_status_weight(uuid, uuid, public.student_attendance_status, numeric) to authenticated;

alter table public.attendance_day add column arrival_time time;
alter table public.attendance_day add column departure_time time;

-- AC1/AC3: present_days now sums attendance_weight() per row instead of
-- an inline case expression — everything else is identical to FR-G14's
-- own version.
create or replace function public.compute_month_attendance(p_campus_id uuid, p_year int, p_month int)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_month_start date := make_date(p_year, p_month, 1);
  v_month_end   date := (v_month_start + interval '1 month' - interval '1 day')::date;
  v_row         record;
  v_from        date;
  v_to          date;
  v_working     int;
  v_present     numeric(5, 2);
  v_absent      int;
  v_late        int;
  v_half        int;
  v_leave       int;
  v_count       int := 0;
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() not in ('super_admin', 'owner', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;

  for v_row in
    select e.id as enrolment_id, e.tenant_id, e.campus_id, e.session_id, e.joined_on, e.left_on
      from public.enrolment e
     where e.campus_id = p_campus_id
       and e.joined_on <= v_month_end
       and (e.left_on is null or e.left_on >= v_month_start)
  loop
    v_from := greatest(v_month_start, v_row.joined_on);
    v_to   := least(v_month_end, coalesce(v_row.left_on, v_month_end));

    if v_from > v_to then
      v_working := 0;
    else
      v_working := public.working_days_between(p_campus_id, v_from, v_to)::int;
    end if;

    select
      coalesce(sum(public.attendance_weight(status, p_campus_id, v_row.session_id)), 0),
      count(*) filter (where status = 'absent'),
      count(*) filter (where status = 'late'),
      count(*) filter (where status = 'half_day'),
      count(*) filter (where status = 'excused')
      into v_present, v_absent, v_late, v_half, v_leave
      from public.attendance_day
     where enrolment_id = v_row.enrolment_id
       and attendance_date between v_from and v_to;

    insert into public.attendance_month_summary (
      tenant_id, campus_id, session_id, enrolment_id, year, month,
      working_days, present_days, absent_days, late_count, half_day_count, leave_days,
      attendance_pct, computed_at
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.session_id, v_row.enrolment_id, p_year, p_month,
      v_working, v_present, v_absent, v_late, v_half, v_leave,
      case when v_working = 0 then null else round(v_present / v_working * 100, 2) end,
      clock_timestamp()
    )
    on conflict (enrolment_id, year, month) do update
       set working_days   = excluded.working_days,
           present_days   = excluded.present_days,
           absent_days    = excluded.absent_days,
           late_count     = excluded.late_count,
           half_day_count = excluded.half_day_count,
           leave_days     = excluded.leave_days,
           attendance_pct = excluded.attendance_pct,
           recomputed_at  = clock_timestamp(),
           stale          = false;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.compute_month_attendance(uuid, int, int) from public, anon;
grant execute on function public.compute_month_attendance(uuid, int, int) to authenticated, service_role;

-- AC2/AC4: a 'late' mark with no arrival_time supplied gets the campus's
-- own local wall-clock time; every other status just stores whatever
-- arrival_time/departure_time it was given (or null) — no weight impact
-- either way, attendance_weight() never looks at these columns.
create or replace function public.save_attendance_register(p_section_id uuid, p_attendance_date date, p_marks jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_section       public.class_section%rowtype;
  v_campus_tz     text;
  v_holiday       text;
  v_policy        jsonb;
  v_mark          record;
  v_arrival       time;
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

  v_holiday := public.resolve_attendance_holiday(v_section.campus_id, p_attendance_date);
  if v_holiday is not null then
    raise exception using message = 'HOLIDAY:' || v_holiday, errcode = '55000';
  end if;

  v_policy := public.resolve_attendance_policy(v_section.campus_id, v_section.session_id);
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

    v_arrival := case
      when v_mark.status = 'late' and v_mark.arrival_time is null then (clock_timestamp() at time zone v_campus_tz)::time
      else v_mark.arrival_time
    end;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, marked_by, arrival_time, departure_time
    ) values (
      v_tenant_id, v_section.campus_id, v_section.session_id, p_section_id, v_mark.enrolment_id, p_attendance_date, v_mark.status, auth.uid(),
      v_arrival, v_mark.departure_time
    )
    on conflict (enrolment_id, attendance_date) do update
      set status = excluded.status, marked_by = excluded.marked_by, marked_at = clock_timestamp(),
          arrival_time = excluded.arrival_time, departure_time = excluded.departure_time;

    v_saved := v_saved + 1;
  end loop;

  return jsonb_build_object('saved', v_saved);
end;
$$;

revoke execute on function public.save_attendance_register(uuid, date, jsonb) from public, anon;
grant execute on function public.save_attendance_register(uuid, date, jsonb) to authenticated;

-- Re-declared only to thread arrival_time/departure_time through to
-- save_attendance_register() — every exception's own extra fields would
-- otherwise be silently dropped by the jsonb_to_recordset column list
-- FR-G04 originally declared, since it never named those two columns.
create or replace function public.rpc_bulk_mark_attendance(p_section_id uuid, p_date date, p_exceptions jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_marks jsonb;
begin
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'enrolment_id', e.id,
      'status', coalesce(x.status, 'present'),
      'arrival_time', x.arrival_time,
      'departure_time', x.departure_time
    )),
    '[]'::jsonb
  )
    into v_marks
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join jsonb_to_recordset(p_exceptions)
      as x(enrolment_id uuid, status public.student_attendance_status, arrival_time time, departure_time time)
      on x.enrolment_id = e.id
   where e.section_id = p_section_id and e.status = 'active' and s.status = 'active';

  return public.save_attendance_register(p_section_id, p_date, v_marks);
end;
$$;

revoke execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb) from public, anon;
grant execute on function public.rpc_bulk_mark_attendance(uuid, date, jsonb) to authenticated;
