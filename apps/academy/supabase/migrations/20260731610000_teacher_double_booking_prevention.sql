-- FR-F05: teacher double-booking prevention.
--
-- Every AC here is a hard reject ("the write is rejected with
-- TEACHER_CLASH"), never a soft flag — unlike FR-D03's teach-scope
-- exceptions, nothing in this FR asks for a non-blocking worklist. So the
-- Supabase Objects spec's `timetable_conflict` table and its
-- `check_teacher_clash()` setof-returning function are NOT built: there's
-- no AC that reads them, and building an unused worklist table would be
-- speculative. The clash check lives directly inside upsert_timetable_slot()
-- (FR-F04's own function), matching this session's established "function-
-- gated write, no redundant trigger" convention rather than the spec's
-- literal constraint-trigger design — same deviation already made for
-- SUBJECT_NOT_OFFERED/VERSION_IMMUTABLE in that same function.
--
-- resolve_bell_template_for_weekday() exists because resolve_bell_template()
-- (FR-F02) takes a specific calendar date, but a timetable_slot is a
-- recurring weekly cell with no date of its own — only a weekday. Matching
-- weekday-rule precedence directly (never date-range rules, which
-- shouldn't apply to a recurring resolution) is the correct semantics here,
-- not an approximation of resolve_bell_template() with a fabricated date.

create or replace function public.resolve_bell_template_for_weekday(p_campus_id uuid, p_shift public.section_shift, p_weekday smallint)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select bell_template_id
        from public.bell_calendar_rule
       where campus_id = p_campus_id
         and shift = p_shift
         and tenant_id = app.auth_tenant_id()
         and weekday = p_weekday
         and date_from is null
       order by precedence desc
       limit 1
    ),
    (
      select id from public.bell_template
       where campus_id = p_campus_id and shift = p_shift and tenant_id = app.auth_tenant_id() and is_default
    )
  );
$$;

revoke execute on function public.resolve_bell_template_for_weekday(uuid, public.section_shift, smallint) from public, anon;
grant execute on function public.resolve_bell_template_for_weekday(uuid, public.section_shift, smallint) to authenticated;

-- AC: "the check compares resolved time ranges, not period numbers" — this
-- view is that resolution, one row per staffed slot.
create or replace view public.v_slot_clock_time with (security_invoker = true) as
select
  ts.id as slot_id,
  ts.tenant_id,
  ts.campus_id,
  ts.timetable_version_id,
  ts.section_id,
  ts.staff_id,
  ts.weekday,
  ts.period_no,
  bp.start_time,
  bp.end_time
from public.timetable_slot ts
join public.timetable_version tv on tv.id = ts.timetable_version_id
join public.bell_period bp
  on bp.bell_template_id = public.resolve_bell_template_for_weekday(ts.campus_id, tv.shift, ts.weekday)
 and bp.period_no = ts.period_no
where ts.staff_id is not null;

create or replace function public.upsert_timetable_slot(
  p_version_id uuid,
  p_section_id uuid,
  p_weekday smallint,
  p_period_no smallint,
  p_subject_id uuid,
  p_staff_id uuid default null,
  p_room_id uuid default null,
  p_elective_bucket smallint default null,
  p_parallel_group_id uuid default null,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id       uuid := app.auth_tenant_id();
  v_campus_id       uuid;
  v_shift           public.section_shift;
  v_version_status  public.timetable_version_status;
  v_class_level_id  uuid;
  v_stream_id       uuid;
  v_self_start      time;
  v_self_end        time;
  v_clash_section   text;
  v_clash_start     time;
  v_clash_end       time;
  v_id              uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, shift, status into v_campus_id, v_shift, v_version_status
    from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_version_status <> 'DRAFT' then
    raise exception 'VERSION_IMMUTABLE' using errcode = '55000';
  end if;

  select class_level_id, stream_id into v_class_level_id, v_stream_id
    from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if v_class_level_id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.class_subject cs
     where cs.class_level_id = v_class_level_id
       and (cs.stream_id is null or cs.stream_id = v_stream_id)
       and cs.subject_id = p_subject_id
  ) then
    raise exception 'SUBJECT_NOT_OFFERED' using errcode = '23514';
  end if;

  if p_staff_id is not null then
    -- Serializes concurrent writes for the same teacher so two racing
    -- transactions can't both pass the clash check against a snapshot
    -- that doesn't yet see the other's uncommitted insert — a plain
    -- unique/exclude constraint can't express this since the clash
    -- condition depends on a resolved bell-period join, not raw columns.
    perform pg_advisory_xact_lock(hashtextextended('teacher-clash:' || p_staff_id::text, 0));

    select bp.start_time, bp.end_time into v_self_start, v_self_end
      from public.bell_period bp
     where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_campus_id, v_shift, p_weekday)
       and bp.period_no = p_period_no;

    if v_self_start is not null then
      select cs.name, vct.start_time, vct.end_time
        into v_clash_section, v_clash_start, v_clash_end
        from public.v_slot_clock_time vct
        join public.class_section cs on cs.id = vct.section_id
       where vct.tenant_id = v_tenant_id
         and vct.staff_id = p_staff_id
         and vct.weekday = p_weekday
         and not (vct.timetable_version_id = p_version_id and vct.section_id = p_section_id and vct.period_no = p_period_no)
         and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
       limit 1;

      if found then
        raise exception 'TEACHER_CLASH: section % at %-%', v_clash_section, to_char(v_clash_start, 'HH24:MI'), to_char(v_clash_end, 'HH24:MI')
          using errcode = '23514';
      end if;
    end if;
  end if;

  insert into public.timetable_slot (
    tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no,
    subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
  )
  values (
    v_tenant_id, v_campus_id, p_version_id, p_section_id, p_weekday, p_period_no,
    p_subject_id, p_staff_id, p_room_id, p_elective_bucket, p_parallel_group_id, p_note
  )
  on conflict (timetable_version_id, section_id, weekday, period_no)
  do update set
    subject_id = excluded.subject_id,
    staff_id = excluded.staff_id,
    room_id = excluded.room_id,
    elective_bucket = excluded.elective_bucket,
    parallel_group_id = excluded.parallel_group_id,
    note = excluded.note
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text) from public, anon;
grant execute on function public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text) to authenticated;
