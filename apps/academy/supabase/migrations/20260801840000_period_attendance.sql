-- FR-G03: period-wise attendance for senior classes.
--
-- When a campus runs attendance in 'period' mode the subject teacher marks
-- the students in their own timetable slot, and the day is derived: present
-- in no period = absent, in fewer than half = half_day, otherwise present
-- (excused periods do not count against the student; present and late count
-- as attended, half_day as half). The denominator is the periods that were
-- actually marked for that student, so a period nobody took cannot turn a
-- present student into a half-day.
--
-- A day mark made by hand always wins: derivation never overwrites a row
-- whose source is not 'derived'. The disagreement is recorded in
-- attendance_derivation_conflict instead, so the Class Teacher's correction
-- is not silently undone by the nightly job and the difference stays visible.
--
-- Editing a period after its day was derived re-derives that one day at once
-- (an AFTER trigger), inside the 60 seconds the requirement allows. A day that
-- was never derived is left for the nightly run (21:00 PKT) so a half-marked
-- day is not published, and the absentee alert is not fired, from the first
-- period alone.
--
-- Elective slots (elective_bucket set) list only the students whose
-- student_elective_choice for that bucket is the slot's subject, not the
-- section roster.

create table public.attendance_period (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  timetable_slot_id uuid not null references public.timetable_slot(id) on delete cascade,
  subject_id        uuid not null references public.subject(id),
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  attendance_date   date not null,
  status            public.student_attendance_status not null,
  marked_by         uuid references public.app_user(user_id),
  marked_at         timestamptz not null default clock_timestamp(),
  constraint uq_attendance_period unique (enrolment_id, timetable_slot_id, attendance_date)
);
create index idx_att_period_slot_date on public.attendance_period (timetable_slot_id, attendance_date);
create index idx_att_period_campus_date on public.attendance_period (tenant_id, campus_id, attendance_date);
create index idx_att_period_enrol_date on public.attendance_period (enrolment_id, attendance_date);
create index idx_att_period_subject on public.attendance_period (subject_id);
create index idx_att_period_session on public.attendance_period (session_id);

create table public.attendance_derivation_conflict (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  attendance_date date not null,
  manual_status   public.student_attendance_status not null,
  manual_source   public.student_attendance_source not null,
  derived_status  public.student_attendance_status not null,
  detected_at     timestamptz not null default clock_timestamp(),
  constraint uq_derivation_conflict unique (enrolment_id, attendance_date)
);
create index idx_derivation_conflict_scope on public.attendance_derivation_conflict (tenant_id, campus_id, attendance_date);

create trigger attendance_period_audit after insert or update or delete on public.attendance_period
  for each row execute function app.tg_audit_row();

alter table public.attendance_period enable row level security;
alter table public.attendance_derivation_conflict enable row level security;

-- A teacher reaches a slot by owning it or by covering it on that date.
create or replace function app.fn_teaches_slot(p_slot_id uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.timetable_slot s where s.id = p_slot_id and s.staff_id = (select auth.uid()))
      or exists (select 1 from public.timetable_substitution sub
                  where sub.slot_id = p_slot_id and sub.sub_date = p_date and sub.substitute_staff_id = (select auth.uid()));
$$;
revoke execute on function app.fn_teaches_slot(uuid, date) from public, anon;
grant execute on function app.fn_teaches_slot(uuid, date) to authenticated;

create policy att_period_teacher_scope on public.attendance_period for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'none', 'accountant')
    and (
      (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller')
        and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())))
      or app.fn_teaches_slot(timetable_slot_id, attendance_date)
    )
  );

create policy att_derivation_conflict_read on public.attendance_derivation_conflict for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'class_teacher')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- ── roster ────────────────────────────────────────────────────────────────

create or replace function app.fn_slot_access(p_slot_id uuid, p_date date)
returns public.timetable_slot
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot public.timetable_slot%rowtype;
begin
  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('super_admin', 'owner') then
    null;
  elsif app.auth_role() in ('principal', 'vice_principal', 'exam_controller') then
    if not (v_slot.campus_id = any(app.auth_campus_ids())) then
      raise exception 'NOT_ASSIGNED_TO_THIS_PERIOD' using errcode = '42501';
    end if;
  elsif not app.fn_teaches_slot(p_slot_id, p_date) then
    raise exception 'NOT_ASSIGNED_TO_THIS_PERIOD' using errcode = '42501';
  end if;
  return v_slot;
end;
$$;
revoke execute on function app.fn_slot_access(uuid, date) from public, anon, authenticated;

create or replace function public.period_attendance_roster(p_slot_id uuid, p_date date)
returns table (enrolment_id uuid, student_name text, gr_number text, status public.student_attendance_status)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_slot public.timetable_slot%rowtype;
  v_session uuid;
begin
  v_slot := app.fn_slot_access(p_slot_id, p_date);
  select v.session_id into v_session from public.timetable_version v where v.id = v_slot.timetable_version_id;
  return query
  select e.id, s.name_en, s.gr_number, ap.status
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join public.attendance_period ap on ap.enrolment_id = e.id and ap.timetable_slot_id = p_slot_id and ap.attendance_date = p_date
   where e.section_id = v_slot.section_id and e.session_id = v_session
     and e.status = 'active' and e.deleted_at is null and s.deleted_at is null
     and (v_slot.elective_bucket is null
          or exists (select 1 from public.student_elective_choice c
                      where c.student_id = e.student_id and c.session_id = e.session_id and c.class_level_id = e.class_level_id
                        and c.elective_bucket = v_slot.elective_bucket and c.subject_id = v_slot.subject_id))
   order by s.name_en;
end;
$$;
revoke execute on function public.period_attendance_roster(uuid, date) from public, anon;
grant execute on function public.period_attendance_roster(uuid, date) to authenticated;

-- The slots the caller may mark on a date: their own and any they cover, or
-- the whole campus for a Principal.
create or replace function public.period_attendance_slots(p_date date)
returns table (slot_id uuid, section_label text, period_no smallint, subject_name text, marked_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, cl.name_en || ' · ' || sec.name, s.period_no, sub.name_en,
         (select count(*) from public.attendance_period ap where ap.timetable_slot_id = s.id and ap.attendance_date = p_date)
    from public.timetable_slot s
    join public.timetable_version v on v.id = s.timetable_version_id and v.status = 'PUBLISHED'
    join public.class_section sec on sec.id = s.section_id
    join public.class_level cl on cl.id = sec.class_level_id
    join public.subject sub on sub.id = s.subject_id
   where s.tenant_id = app.auth_tenant_id() and s.weekday = extract(dow from p_date)::smallint
     and (
       app.auth_role() in ('super_admin', 'owner')
       or (app.auth_role() in ('principal', 'vice_principal', 'exam_controller') and s.campus_id = any(app.auth_campus_ids()))
       or app.fn_teaches_slot(s.id, p_date)
     )
   order by s.period_no, 2;
$$;
revoke execute on function public.period_attendance_slots(date) from public, anon;
grant execute on function public.period_attendance_slots(date) to authenticated;

-- ── marking ───────────────────────────────────────────────────────────────

create or replace function public.save_period_attendance(p_slot_id uuid, p_date date, p_marks jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot   public.timetable_slot%rowtype;
  v_ver    public.timetable_version%rowtype;
  v_policy jsonb;
  v_holiday text;
  v_bad    int;
  v_saved  int;
begin
  v_slot := app.fn_slot_access(p_slot_id, p_date);
  select * into v_ver from public.timetable_version where id = v_slot.timetable_version_id;
  if v_ver.status <> 'PUBLISHED' then
    raise exception 'TIMETABLE_NOT_PUBLISHED' using errcode = '55000';
  end if;
  if p_date > app.fn_karachi_today() then
    raise exception 'DATE_IN_FUTURE' using errcode = '22023';
  end if;
  if extract(dow from p_date)::smallint <> v_slot.weekday then
    raise exception 'DATE_NOT_ON_SLOT_WEEKDAY' using errcode = '22023';
  end if;
  v_policy := app.resolve_attendance_policy_unscoped(v_slot.tenant_id, v_slot.campus_id, v_ver.session_id);
  if v_policy is null or v_policy ->> 'mode' <> 'period' then
    raise exception 'CAMPUS_NOT_IN_PERIOD_MODE' using errcode = '55000';
  end if;
  v_holiday := public.resolve_attendance_holiday(v_slot.campus_id, p_date);
  if v_holiday is not null then
    raise exception 'HOLIDAY: %', v_holiday using errcode = '55000';
  end if;
  if public.is_attendance_locked(v_slot.section_id, p_date) then
    raise exception 'ATTENDANCE_LOCKED' using errcode = '55000';
  end if;
  if jsonb_typeof(p_marks) <> 'array' or jsonb_array_length(p_marks) = 0 or jsonb_array_length(p_marks) > 300 then
    raise exception 'MARKS_MUST_BE_1_TO_300' using errcode = '22023';
  end if;

  select count(*) into v_bad
    from jsonb_to_recordset(p_marks) as m(enrolment_id uuid, status text)
   where not exists (select 1 from public.period_attendance_roster(p_slot_id, p_date) r where r.enrolment_id = m.enrolment_id);
  if v_bad > 0 then
    raise exception 'STUDENT_NOT_ON_THIS_ROSTER' using errcode = '22023', detail = format('count=%s', v_bad);
  end if;

  insert into public.attendance_period (tenant_id, campus_id, session_id, timetable_slot_id, subject_id, enrolment_id, attendance_date, status, marked_by)
  select v_slot.tenant_id, v_slot.campus_id, v_ver.session_id, p_slot_id, v_slot.subject_id, m.enrolment_id, p_date, m.status::public.student_attendance_status, (select auth.uid())
    from jsonb_to_recordset(p_marks) as m(enrolment_id uuid, status text)
  on conflict (enrolment_id, timetable_slot_id, attendance_date)
  do update set status = excluded.status, marked_by = excluded.marked_by, marked_at = clock_timestamp()
     where public.attendance_period.status is distinct from excluded.status;
  get diagnostics v_saved = row_count;
  return jsonb_build_object('saved', v_saved, 'marked', jsonb_array_length(p_marks));
end;
$$;
revoke execute on function public.save_period_attendance(uuid, date, jsonb) from public, anon;
grant execute on function public.save_period_attendance(uuid, date, jsonb) to authenticated;

-- ── derivation ────────────────────────────────────────────────────────────

create or replace function app.fn_derive_day(p_enrolment_id uuid, p_date date)
returns public.student_attendance_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total   int;
  v_denom   int;
  v_attended numeric;
  v_derived public.student_attendance_status;
  v_e       public.enrolment%rowtype;
  v_day     public.attendance_day%rowtype;
begin
  select count(*), count(*) filter (where status <> 'excused'),
         coalesce(sum(case status when 'present' then 1 when 'late' then 1 when 'half_day' then 0.5 else 0 end), 0)
    into v_total, v_denom, v_attended
    from public.attendance_period where enrolment_id = p_enrolment_id and attendance_date = p_date;
  if v_total = 0 then
    return null;
  end if;
  v_derived := case when v_denom = 0 then 'excused' when v_attended = 0 then 'absent' when v_attended < v_denom / 2.0 then 'half_day' else 'present' end;

  select * into v_e from public.enrolment where id = p_enrolment_id;
  select * into v_day from public.attendance_day where enrolment_id = p_enrolment_id and attendance_date = p_date;
  if not found then
    insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
    values (v_e.tenant_id, v_e.campus_id, v_e.session_id, v_e.section_id, p_enrolment_id, p_date, v_derived, 'derived');
  elsif v_day.source = 'derived' then
    if v_day.status <> v_derived then
      update public.attendance_day set status = v_derived, marked_at = clock_timestamp() where id = v_day.id;
    end if;
    delete from public.attendance_derivation_conflict where enrolment_id = p_enrolment_id and attendance_date = p_date;
  elsif v_day.status <> v_derived then
    insert into public.attendance_derivation_conflict (tenant_id, campus_id, enrolment_id, attendance_date, manual_status, manual_source, derived_status)
    values (v_e.tenant_id, v_e.campus_id, p_enrolment_id, p_date, v_day.status, v_day.source, v_derived)
    on conflict (enrolment_id, attendance_date) do update set manual_status = excluded.manual_status, manual_source = excluded.manual_source,
      derived_status = excluded.derived_status, detected_at = clock_timestamp();
  else
    delete from public.attendance_derivation_conflict where enrolment_id = p_enrolment_id and attendance_date = p_date;
  end if;
  return v_derived;
end;
$$;
revoke execute on function app.fn_derive_day(uuid, date) from public, anon, authenticated;

create or replace function app.tg_period_redrive()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.attendance_day d where d.enrolment_id = new.enrolment_id and d.attendance_date = new.attendance_date) then
    perform app.fn_derive_day(new.enrolment_id, new.attendance_date);
  end if;
  return null;
end;
$$;
create trigger trg_period_redrive after insert or update of status on public.attendance_period
  for each row execute function app.tg_period_redrive();

create or replace function public.derive_day_from_periods(p_campus_id uuid, p_date date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r   record;
  v_n int := 0;
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() not in ('owner', 'super_admin', 'principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  for r in select distinct enrolment_id from public.attendance_period where campus_id = p_campus_id and attendance_date = p_date loop
    perform app.fn_derive_day(r.enrolment_id, p_date);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.derive_day_from_periods(uuid, date) from public, anon;
grant execute on function public.derive_day_from_periods(uuid, date) to authenticated, service_role;

create or replace function public.derive_day_attendance_all()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  c   record;
  v_n int := 0;
begin
  for c in select distinct campus_id from public.attendance_period where attendance_date = app.fn_karachi_today() loop
    v_n := v_n + public.derive_day_from_periods(c.campus_id, app.fn_karachi_today());
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.derive_day_attendance_all() from public, anon, authenticated;
grant execute on function public.derive_day_attendance_all() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('derive_day_attendance', '0 16 * * *', 'select public.derive_day_attendance_all();');
  end if;
exception
  when others then null;
end;
$$;
