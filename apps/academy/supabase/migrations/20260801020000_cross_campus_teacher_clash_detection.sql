-- Fix: FR-F05's TEACHER_CLASH (and FR-D13's SUBSTITUTE_CLASH) stopped
-- firing for a teacher shared across campuses, silently, for every actor
-- except an Owner/Super Admin.
--
-- 20260731770000_security_definer_campus_scope_audit.sql put a campus
-- guard on resolve_bell_template_for_weekday(): out-of-scope campus →
-- NULL. public.v_slot_clock_time INNER joins bell_period on that
-- resolution, so a slot at a campus outside the caller's campus_ids
-- claim now resolves to NULL and drops out of the view entirely.
--
-- upsert_timetable_slot() queries that view tenant-wide by staff_id ON
-- PURPOSE — FR-F05 is a physical-presence invariant, not a per-campus
-- bookkeeping rule: a teacher shared between two campuses cannot be in
-- both at 08:30, so the competing booking has to be visible wherever it
-- lives. After the audit it was not. A Principal scoped to campus A
-- booking a teacher who is already teaching at campus B at an
-- overlapping clock time got no exception at all — the write succeeded
-- and the double-booking was created. The same write as an Owner
-- correctly raised 23514, which is exactly the shape of a guard leaking
-- into a place it was never meant to reach: the safety control silently
-- weakened for the role that actually does the timetabling.
-- create_substitution() (FR-D13) has the identical defect for the same
-- reason — its SUBSTITUTE_CLASH check reads the same view by
-- substitute_staff_id, tenant-wide.
--
-- Fix shape: the same split 20260801010000 established for
-- resolve_bell_template(), applied to the weekday variant and to the
-- view built on it —
--
--   app.resolve_bell_template_for_weekday_unscoped()  the resolution
--                                       logic (unchanged from FR-F05,
--                                       still tenant-scoped)
--   public.resolve_bell_template_for_weekday()  that logic behind the
--                                       campus guard, byte-for-byte the
--                                       behaviour the audit left, for
--                                       every ordinary caller
--   app.v_slot_clock_time_unscoped      the resolved-clock-time view
--                                       over the unscoped resolver
--   public.v_slot_clock_time            unchanged, still the guarded,
--                                       security_invoker, RLS-respecting
--                                       view every direct reader uses
--
-- Neither internal object is a general-purpose bypass, for the reasons
-- 20260801010000 set out in full and which hold here identically:
--   * both live in `app`, which PostgREST does not expose (config.toml
--     schemas = public, graphql_public), so neither has an HTTP surface;
--   * EXECUTE on the resolver and SELECT on the view are revoked from
--     public, anon AND authenticated, so only a postgres-owned SECURITY
--     DEFINER function — one that has already run its own access check —
--     can reach them;
--   * they are CAMPUS-scope escape hatches, never tenant ones: the
--     tenant_id = app.auth_tenant_id() predicate stays in the resolver
--     body, and every caller below still filters vct.tenant_id itself.
--
-- DETECTING a clash and DISCLOSING it are separated deliberately. The
-- existing message names the competing section and its clock range,
-- which is right when the caller can already read that section and
-- wrong when it belongs to a campus they are not scoped to. So the
-- detailed message is now conditional on the CLASHING slot's campus
-- being one the caller may see; otherwise the write is still refused
-- with 23514, but the message names no campus, no section, no class, no
-- subject, no room and no clock time — only that this teacher is
-- already booked at another campus in an overlapping period. That is
-- the minimum a Principal needs to know the refusal is real (and to
-- escalate to someone who can see both campuses) and is strictly less
-- than resolve_bell_template's own guard was hiding: it conveys the
-- existence of a scheduling conflict, nothing that identifies it. When
-- both an in-scope and an out-of-scope slot clash, the in-scope one is
-- reported, so the caller always gets the most actionable message they
-- are entitled to.
--
-- Deliberately NOT changed here:
--   * upsert_timetable_slot()'s ROOM_CLASH and room-capacity queries
--     still read public.v_slot_clock_time. A room belongs to one campus
--     and is only ever booked by that campus's own slots, so those
--     queries have no cross-campus case to lose — and ROOM_CLASH's
--     message names a section, which under the guarded view can only
--     ever be one the caller can already read. Widening them would
--     trade a real property for no coverage.
--   * public.v_slot_clock_time itself. It is `authenticated`-readable
--     and security_invoker; pointing it at the unscoped resolver would
--     either break every direct reader (no EXECUTE) or require granting
--     that EXECUTE, which is the bypass this file exists to avoid.

create or replace function app.resolve_bell_template_for_weekday_unscoped(p_campus_id uuid, p_shift public.section_shift, p_weekday smallint)
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

revoke execute on function app.resolve_bell_template_for_weekday_unscoped(uuid, public.section_shift, smallint) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: an out-of-scope campus
-- still resolves to NULL, silently, exactly as the audit migration left
-- it.
create or replace function public.resolve_bell_template_for_weekday(p_campus_id uuid, p_shift public.section_shift, p_weekday smallint)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then null
    else app.resolve_bell_template_for_weekday_unscoped(p_campus_id, p_shift, p_weekday)
  end;
$$;

-- Column-for-column public.v_slot_clock_time (FR-F06's shape, including
-- room_id), differing only in which resolver supplies the clock time.
create or replace view app.v_slot_clock_time_unscoped with (security_invoker = true) as
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
  on bp.bell_template_id = app.resolve_bell_template_for_weekday_unscoped(ts.campus_id, tv.shift, ts.weekday)
 and bp.period_no = ts.period_no
where ts.staff_id is not null or ts.room_id is not null;

revoke all on app.v_slot_clock_time_unscoped from public, anon, authenticated;

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
  v_role            text := app.auth_role();
  v_campus_ids      uuid[] := app.auth_campus_ids();
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
  v_clash_visible   boolean;
  v_clash_section   text;
  v_clash_start     time;
  v_clash_end       time;
  v_total_students  int;
  v_room_capacity   int;
  v_old_room_id     uuid;
  v_id              uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id, shift, status into v_campus_id, v_shift, v_version_status
    from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_campus_id = any(v_campus_ids)) then
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

    -- This campus is already known to be in scope (checked above), so the
    -- guarded resolver is the right one for the slot being written.
    select bp.start_time, bp.end_time into v_self_start, v_self_end
      from public.bell_period bp
     where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_campus_id, v_shift, p_weekday)
       and bp.period_no = p_period_no;

    if v_self_start is not null then
      -- Unscoped deliberately: a teacher cannot be in two places at once
      -- regardless of which of those places this caller administers.
      select (v_role in ('super_admin', 'owner') or vct.campus_id = any(v_campus_ids)), cs.name, vct.start_time, vct.end_time
        into v_clash_visible, v_clash_section, v_clash_start, v_clash_end
        from app.v_slot_clock_time_unscoped vct
        join public.class_section cs on cs.id = vct.section_id
       where vct.tenant_id = v_tenant_id
         and vct.staff_id = p_staff_id
         and vct.weekday = p_weekday
         and not (vct.timetable_version_id = p_version_id and vct.section_id = p_section_id and vct.period_no = p_period_no)
         and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
       order by 1 desc
       limit 1;

      if found then
        if v_clash_visible then
          raise exception 'TEACHER_CLASH: section % at %-%', v_clash_section, to_char(v_clash_start, 'HH24:MI'), to_char(v_clash_end, 'HH24:MI')
            using errcode = '23514';
        else
          -- Names nothing about the other campus — not its name, its
          -- section, its class, its subject, its room, nor the competing
          -- clock range. Only that the refusal is real.
          raise exception 'TEACHER_CLASH: this teacher is already booked at another campus in an overlapping period'
            using errcode = '23514';
        end if;
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

-- FR-D13's SUBSTITUTE_CLASH is the same physical-presence invariant as
-- FR-F05's, checked the same way against the same view, and lost the
-- same coverage. It discloses nothing about the competing booking (the
-- message is the bare token), so it needs no visibility branch — only
-- the unscoped view.
create or replace function public.create_substitution(
  p_slot_id uuid, p_sub_date date, p_substitute_staff_id uuid, p_reason public.substitution_reason default 'other'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_slot       public.timetable_slot%rowtype;
  v_shift      public.section_shift;
  v_self_start time;
  v_self_end   time;
  v_clash      boolean;
  v_id         uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_slot.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_slot.staff_id is null then
    raise exception 'SLOT_HAS_NO_TEACHER' using errcode = '23514';
  end if;
  if extract(dow from p_sub_date)::smallint <> v_slot.weekday then
    raise exception 'SUB_DATE_WEEKDAY_MISMATCH' using errcode = '23514';
  end if;
  if p_substitute_staff_id = v_slot.staff_id then
    raise exception 'SUBSTITUTE_IS_ABSENT_TEACHER' using errcode = '23514';
  end if;

  -- Same reasoning as upsert_timetable_slot's per-teacher lock: serializes
  -- two racing assignments of the same substitute so neither's clash check
  -- runs against a snapshot that doesn't yet see the other's insert.
  perform pg_advisory_xact_lock(hashtextextended('substitution:' || p_substitute_staff_id::text || p_sub_date::text, 0));

  select tv.shift into v_shift from public.timetable_version tv where tv.id = v_slot.timetable_version_id;

  -- This slot's own campus passed the scope check above.
  select bp.start_time, bp.end_time into v_self_start, v_self_end
    from public.bell_period bp
   where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_slot.campus_id, v_shift, v_slot.weekday)
     and bp.period_no = v_slot.period_no;

  if v_self_start is not null then
    select
      exists (
        select 1 from app.v_slot_clock_time_unscoped vct
         where vct.tenant_id = v_tenant_id and vct.staff_id = p_substitute_staff_id and vct.weekday = v_slot.weekday
           and vct.slot_id <> v_slot.id
           and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
      )
      or exists (
        select 1
          from public.timetable_substitution other_sub
          join app.v_slot_clock_time_unscoped other_vct on other_vct.slot_id = other_sub.slot_id
         where other_sub.substitute_staff_id = p_substitute_staff_id
           and other_sub.sub_date = p_sub_date
           and other_sub.status = 'active'
           and other_sub.slot_id <> p_slot_id
           and public.timerange(other_vct.start_time, other_vct.end_time) && public.timerange(v_self_start, v_self_end)
      )
      into v_clash;

    if v_clash then
      raise exception 'SUBSTITUTE_CLASH' using errcode = '23514';
    end if;
  end if;

  insert into public.timetable_substitution (
    tenant_id, campus_id, slot_id, sub_date, absent_staff_id, substitute_staff_id, reason, status, created_by
  )
  values (
    v_tenant_id, v_slot.campus_id, p_slot_id, p_sub_date, v_slot.staff_id, p_substitute_staff_id, p_reason, 'active', auth.uid()
  )
  on conflict (slot_id, sub_date) do update set
    substitute_staff_id = excluded.substitute_staff_id,
    reason = excluded.reason,
    status = 'active',
    created_by = excluded.created_by
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_substitution(uuid, date, uuid, public.substitution_reason) from public, anon;
grant execute on function public.create_substitution(uuid, date, uuid, public.substitution_reason) to authenticated;

-- The candidate ranking must agree with the write it feeds, or the
-- screen offers a teacher create_substitution() then hard-rejects.
-- is_free is a bare boolean: it says this candidate is busy somewhere in
-- an overlapping period, never where, for whom, or in what.
create or replace function public.suggest_substitutes(p_slot_id uuid, p_sub_date date)
returns table (
  staff_id uuid, full_name text, is_free boolean, can_teach_subject boolean, periods_covered_today int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_slot           public.timetable_slot%rowtype;
  v_shift          public.section_shift;
  v_class_level_id uuid;
  v_stream_id      uuid;
  v_self_start     time;
  v_self_end       time;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_slot from public.timetable_slot where id = p_slot_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SLOT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if extract(dow from p_sub_date)::smallint <> v_slot.weekday then
    raise exception 'SUB_DATE_WEEKDAY_MISMATCH' using errcode = '23514';
  end if;

  select tv.shift into v_shift from public.timetable_version tv where tv.id = v_slot.timetable_version_id;
  select cs.class_level_id, cs.stream_id into v_class_level_id, v_stream_id
    from public.class_section cs where cs.id = v_slot.section_id;

  select bp.start_time, bp.end_time into v_self_start, v_self_end
    from public.bell_period bp
   where bp.bell_template_id = public.resolve_bell_template_for_weekday(v_slot.campus_id, v_shift, v_slot.weekday)
     and bp.period_no = v_slot.period_no;

  return query
    select
      au.user_id,
      au.full_name,
      (
        v_self_start is null
        or (
          not exists (
            select 1 from app.v_slot_clock_time_unscoped vct
             where vct.tenant_id = v_tenant_id and vct.staff_id = au.user_id and vct.weekday = v_slot.weekday
               and vct.slot_id <> v_slot.id
               and public.timerange(vct.start_time, vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
          and not exists (
            select 1
              from public.timetable_substitution other_sub
              join app.v_slot_clock_time_unscoped other_vct on other_vct.slot_id = other_sub.slot_id
             where other_sub.substitute_staff_id = au.user_id
               and other_sub.sub_date = p_sub_date
               and other_sub.status = 'active'
               and other_sub.slot_id <> p_slot_id
               and public.timerange(other_vct.start_time, other_vct.end_time) && public.timerange(v_self_start, v_self_end)
          )
        )
      ) as is_free,
      public.can_teach(au.user_id, v_slot.subject_id, v_class_level_id, v_stream_id) as can_teach_subject,
      (
        select count(*)::int from public.timetable_substitution ts2
         where ts2.substitute_staff_id = au.user_id and ts2.sub_date = p_sub_date and ts2.status = 'active'
      ) as periods_covered_today
    from public.app_user au
   where au.tenant_id = v_tenant_id
     and au.app_role in ('subject_teacher', 'class_teacher', 'head_of_department')
     and (v_slot.staff_id is null or au.user_id <> v_slot.staff_id)
    order by 3 desc, 4 desc, 5 asc, au.full_name asc;
end;
$$;

revoke execute on function public.suggest_substitutes(uuid, date) from public, anon;
grant execute on function public.suggest_substitutes(uuid, date) to authenticated;
