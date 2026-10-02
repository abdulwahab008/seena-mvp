-- FR-F06: room double-booking prevention.
--
-- Mirrors FR-F05's TEACHER_CLASH exactly: the check lives inline inside
-- upsert_timetable_slot() (this session's own established "function-gated
-- write, no redundant trigger" convention), not the spec's literal
-- constraint-trigger design — same deviation already made for
-- SUBJECT_NOT_OFFERED/TEACHER_CLASH/SECTION_CLASH in that same function.
-- The spec's own partial-unique-index object is skipped for the same
-- reason TEACHER_CLASH has none: the clash must compare resolved CLOCK
-- TIME across versions/shifts (a room free in a Published version's
-- Tuesday-period-3 may be a different real time than a Draft's), which a
-- plain column-equality index can't express.
--
-- AC2's "10-A and 10-B combined under one parallel_group_id" cannot be
-- built literally: FR-F07's timetable_parallel_group is owned by exactly
-- ONE section (it exists to let a single section's students split across
-- electives in the same period), so two DIFFERENT sections can never
-- share one group row. The only version of "deliberately combined" this
-- schema can actually express is two sections booked into the same room
-- at the same time for the SAME subject — a joint lecture is definitionally
-- one subject taught to both sections together. So ROOM_CLASH triggers
-- only when the competing booking is a DIFFERENT subject; a matching
-- subject is treated as an intentional combine and both slots save.
--
-- AC4 (capacity overflow) can't be a hard reject — "the slot still saves"
-- — and a plain `raise warning` is invisible to a supabase-js caller
-- (PostgREST doesn't forward NOTICE/WARNING to the HTTP response). So a
-- small queryable table records the current warning per (version, room,
-- weekday, period), replaced on every write to that room-cell — the same
-- shape as FR-F09's timetable_publish_exception for its own non-blocking
-- shortfall warnings.
--
-- AC5 (room demand report) is NOT built: it requires knowing which
-- subjects need which room_type, and no FR up to this one ever added that
-- link (class_subject has no room_type column). Inventing one here would
-- be speculative schema nobody asked for — out of scope for this FR,
-- same "cut, don't half-build" precedent as FR-F15's print/export.

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
  bp.end_time,
  ts.room_id
from public.timetable_slot ts
join public.timetable_version tv on tv.id = ts.timetable_version_id
join public.bell_period bp
  on bp.bell_template_id = public.resolve_bell_template_for_weekday(ts.campus_id, tv.shift, ts.weekday)
 and bp.period_no = ts.period_no
where ts.staff_id is not null or ts.room_id is not null;

create table public.timetable_room_capacity_warning (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  campus_id             uuid not null references public.campus(id) on delete cascade,
  timetable_version_id  uuid not null references public.timetable_version(id) on delete cascade,
  room_id               uuid not null references public.room(id),
  weekday               smallint not null,
  period_no             smallint not null,
  total_students        int not null,
  room_capacity         int not null,
  created_at            timestamptz not null default now(),
  unique (timetable_version_id, room_id, weekday, period_no)
);

create index idx_room_capacity_warning_version on public.timetable_room_capacity_warning (timetable_version_id);

alter table public.timetable_room_capacity_warning enable row level security;

create policy room_capacity_warning_campus_scope on public.timetable_room_capacity_warning
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

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
  p_note text default null,
  p_override_reason text default null
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
  v_group_weekday   smallint;
  v_group_period    smallint;
  v_group_bucket    smallint;
  v_self_start      time;
  v_self_end        time;
  v_clash_section   text;
  v_clash_start     time;
  v_clash_end       time;
  v_total_students  int;
  v_room_capacity   int;
  v_old_room_id     uuid;
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

  -- Captured before this cell's own room can change below — needed to
  -- recompute (or drop) the room it's about to VACATE's own capacity
  -- warning, which this write would otherwise leave stale.
  if p_parallel_group_id is null then
    select room_id into v_old_room_id from public.timetable_slot
     where timetable_version_id = p_version_id and section_id = p_section_id
       and weekday = p_weekday and period_no = p_period_no and parallel_group_id is null;
  else
    select room_id into v_old_room_id from public.timetable_slot
     where parallel_group_id = p_parallel_group_id and subject_id = p_subject_id;
  end if;

  if p_parallel_group_id is not null then
    if p_elective_bucket is null then
      raise exception 'PARALLEL_BLOCK_REQUIRES_BUCKET' using errcode = '23514';
    end if;

    select weekday, period_no, elective_bucket into v_group_weekday, v_group_period, v_group_bucket
      from public.timetable_parallel_group
     where id = p_parallel_group_id and tenant_id = v_tenant_id and timetable_version_id = p_version_id and section_id = p_section_id;
    if v_group_weekday is null then
      raise exception 'PARALLEL_GROUP_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_group_weekday <> p_weekday or v_group_period <> p_period_no then
      raise exception 'PARALLEL_BLOCK_PERIOD_MISMATCH' using errcode = '23514';
    end if;
    if v_group_bucket <> p_elective_bucket then
      raise exception 'PARALLEL_BLOCK_BUCKET_MISMATCH' using errcode = '23514';
    end if;
    if not exists (
      select 1 from public.class_subject cs2
       where cs2.class_level_id = v_class_level_id
         and (cs2.stream_id is null or cs2.stream_id = v_stream_id)
         and cs2.subject_id = p_subject_id
         and cs2.elective_bucket = p_elective_bucket
    ) then
      raise exception 'SUBJECT_NOT_IN_BUCKET' using errcode = '23514';
    end if;
  else
    -- AC: a plain write is rejected outright if this exact cell is
    -- already committed to an established parallel block — the section-
    -- level double-booking guarantee this FR is named for.
    if exists (
      select 1 from public.timetable_slot
       where timetable_version_id = p_version_id and section_id = p_section_id
         and weekday = p_weekday and period_no = p_period_no and parallel_group_id is not null
    ) then
      raise exception 'SECTION_CLASH' using errcode = '23514';
    end if;
  end if;

  if p_staff_id is not null and not public.can_teach(p_staff_id, p_subject_id, v_class_level_id, v_stream_id) then
    if p_override_reason is null or btrim(p_override_reason) = '' then
      raise exception 'TEACH_SCOPE_VIOLATION' using errcode = '23514';
    end if;
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

  if p_room_id is not null then
    perform pg_advisory_xact_lock(hashtextextended('room-clash:' || p_room_id::text, 0));

    select bp.start_time, bp.end_time into v_self_start, v_self_end
      from public.bell_period bp
     where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_campus_id, v_shift, p_weekday)
       and bp.period_no = p_period_no;

    if v_self_start is not null then
      -- AC2: a DIFFERENT subject competing for this room at an
      -- overlapping time is a real clash; the SAME subject booked by
      -- another section is a deliberate joint/combined lecture.
      select cs.name, vct.start_time, vct.end_time
        into v_clash_section, v_clash_start, v_clash_end
        from public.v_slot_clock_time vct
        join public.class_section cs on cs.id = vct.section_id
        join public.timetable_slot ts2 on ts2.id = vct.slot_id
       where vct.tenant_id = v_tenant_id
         and vct.room_id = p_room_id
         and vct.weekday = p_weekday
         and not (vct.timetable_version_id = p_version_id and vct.section_id = p_section_id and vct.period_no = p_period_no)
         and ts2.subject_id <> p_subject_id
         and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
       limit 1;

      if found then
        raise exception 'ROOM_CLASH: section % at %-%', v_clash_section, to_char(v_clash_start, 'HH24:MI'), to_char(v_clash_end, 'HH24:MI')
          using errcode = '23514';
      end if;

      -- AC4: combined bookings for the same room-cell can overflow the
      -- room — flagged, never blocked. Replaces any prior warning for
      -- this exact room-cell so a fix (or a room swap) clears it.
      select coalesce(sum(cs3.capacity), 0) + (select capacity from public.class_section where id = p_section_id)
        into v_total_students
        from public.v_slot_clock_time vct2
        join public.timetable_slot ts3 on ts3.id = vct2.slot_id
        join public.class_section cs3 on cs3.id = vct2.section_id
       where vct2.tenant_id = v_tenant_id
         and vct2.room_id = p_room_id
         and vct2.weekday = p_weekday
         and not (vct2.timetable_version_id = p_version_id and vct2.section_id = p_section_id and vct2.period_no = p_period_no)
         and ts3.subject_id = p_subject_id
         and public.timerange(vct2.start_time, vct2.end_time) && public.timerange(v_self_start, v_self_end);

      select capacity into v_room_capacity from public.room where id = p_room_id and tenant_id = v_tenant_id;

      delete from public.timetable_room_capacity_warning
       where timetable_version_id = p_version_id and room_id = p_room_id and weekday = p_weekday and period_no = p_period_no;

      if v_room_capacity is not null and v_total_students > v_room_capacity then
        insert into public.timetable_room_capacity_warning
          (tenant_id, campus_id, timetable_version_id, room_id, weekday, period_no, total_students, room_capacity)
        values (v_tenant_id, v_campus_id, p_version_id, p_room_id, p_weekday, p_period_no, v_total_students, v_room_capacity);
      end if;
    end if;
  end if;

  -- This write is moving the cell to a different room (or clearing its
  -- room outright) — the room it's LEAVING may have only been over
  -- capacity because of this section's own contribution, so its warning
  -- (if any) is recomputed from whoever is actually left behind.
  if v_old_room_id is not null and v_old_room_id is distinct from p_room_id then
    select coalesce(sum(cs4.capacity), 0) into v_total_students
      from public.timetable_slot ts4
      join public.class_section cs4 on cs4.id = ts4.section_id
     where ts4.timetable_version_id = p_version_id
       and ts4.room_id = v_old_room_id
       and ts4.weekday = p_weekday
       and ts4.period_no = p_period_no
       and ts4.section_id <> p_section_id;

    select capacity into v_room_capacity from public.room where id = v_old_room_id and tenant_id = v_tenant_id;

    delete from public.timetable_room_capacity_warning
     where timetable_version_id = p_version_id and room_id = v_old_room_id and weekday = p_weekday and period_no = p_period_no;

    if v_room_capacity is not null and v_total_students > v_room_capacity then
      insert into public.timetable_room_capacity_warning
        (tenant_id, campus_id, timetable_version_id, room_id, weekday, period_no, total_students, room_capacity)
      values (v_tenant_id, v_campus_id, p_version_id, v_old_room_id, p_weekday, p_period_no, v_total_students, v_room_capacity);
    end if;
  end if;

  if p_parallel_group_id is null then
    insert into public.timetable_slot (
      tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no,
      subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
    )
    values (
      v_tenant_id, v_campus_id, p_version_id, p_section_id, p_weekday, p_period_no,
      p_subject_id, p_staff_id, p_room_id, p_elective_bucket, p_parallel_group_id, p_note
    )
    on conflict (timetable_version_id, section_id, weekday, period_no) where parallel_group_id is null
    do update set
      subject_id = excluded.subject_id,
      staff_id = excluded.staff_id,
      room_id = excluded.room_id,
      note = excluded.note
    returning id into v_id;
  else
    insert into public.timetable_slot (
      tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no,
      subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
    )
    values (
      v_tenant_id, v_campus_id, p_version_id, p_section_id, p_weekday, p_period_no,
      p_subject_id, p_staff_id, p_room_id, p_elective_bucket, p_parallel_group_id, p_note
    )
    on conflict (parallel_group_id, subject_id) where parallel_group_id is not null
    do update set
      staff_id = excluded.staff_id,
      room_id = excluded.room_id,
      note = excluded.note
    returning id into v_id;
  end if;

  -- AC: an override is recorded per-write, naming who approved it and why
  -- — never a standing exemption. A prior override row for this exact
  -- cell (from an earlier save) is superseded, not accumulated.
  delete from public.teach_scope_override where assignment_type = 'timetable_slot' and assignment_id = v_id;
  if p_staff_id is not null and p_override_reason is not null and btrim(p_override_reason) <> ''
     and not public.can_teach(p_staff_id, p_subject_id, v_class_level_id, v_stream_id) then
    insert into public.teach_scope_override (tenant_id, assignment_type, assignment_id, approved_by, reason)
    values (v_tenant_id, 'timetable_slot', v_id, auth.uid(), p_override_reason);
  end if;

  return v_id;
end;
$$;

revoke execute on function public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text, text) from public, anon;
grant execute on function public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text, text) to authenticated;

-- clear_timetable_slot() re-declared purely to also drop this cell's own
-- room-capacity warning (if any) — otherwise clearing one half of a
-- combined booking leaves a stale ROOM_CAPACITY_EXCEEDED warning behind
-- for a room-cell that may no longer even be combined.
create or replace function public.clear_timetable_slot(p_version_id uuid, p_section_id uuid, p_weekday smallint, p_period_no smallint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_campus_id      uuid;
  v_version_status public.timetable_version_status;
  v_room_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, status into v_campus_id, v_version_status
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

  select room_id into v_room_id from public.timetable_slot
   where timetable_version_id = p_version_id and section_id = p_section_id
     and weekday = p_weekday and period_no = p_period_no;

  delete from public.timetable_slot
   where timetable_version_id = p_version_id and section_id = p_section_id
     and weekday = p_weekday and period_no = p_period_no;

  if v_room_id is not null then
    delete from public.timetable_room_capacity_warning
     where timetable_version_id = p_version_id and room_id = v_room_id
       and weekday = p_weekday and period_no = p_period_no;
  end if;
end;
$$;

revoke execute on function public.clear_timetable_slot(uuid, uuid, smallint, smallint) from public, anon;
grant execute on function public.clear_timetable_slot(uuid, uuid, smallint, smallint) to authenticated;
