-- FR-D03: teachable subject and grade matrix.
--
-- Deviation from the spec's literal `grade_from smallint, grade_to
-- smallint` columns: class_level has no numeric "grade" of its own, only
-- an ordinal sequence position (nursery/KG sit before grade 1, so ordinal
-- and human grade number don't coincide). Storing two class_level FKs
-- instead of raw integers avoids inventing a parallel numbering scheme
-- and lets the admin UI offer a level picker instead of asking someone to
-- know grade-to-ordinal offsets by heart. can_teach() still resolves the
-- comparison via class_level.ordinal underneath.
--
-- trg_validate_substitution_teacher (the spec's own second trigger) is
-- not built — it validates public.timetable_substitution, which is
-- FR-D13's own table and doesn't exist yet. Same "gate what exists today"
-- precedent as every other cross-module dependency cut this session.
--
-- The scope check lives inside upsert_timetable_slot() (now on its third
-- extension, after FR-F04 and FR-F05), not a BEFORE trigger on
-- timetable_slot — that function is this codebase's only write path for
-- that table (no RLS insert/update policy exists for `authenticated`), so
-- a trigger would just duplicate the same check with no additional
-- coverage, the same reasoning already applied to SUBJECT_NOT_OFFERED and
-- VERSION_IMMUTABLE.

create table public.staff_teachable_subject (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  staff_id            uuid not null references public.app_user(user_id) on delete cascade,
  subject_id          uuid not null references public.subject(id),
  class_level_from_id uuid not null references public.class_level(id),
  class_level_to_id   uuid not null references public.class_level(id),
  stream_id           uuid references public.stream(id),
  created_at          timestamptz not null default now()
);

create index idx_teachable_staff_subject on public.staff_teachable_subject (staff_id, subject_id);
create index idx_teachable_tenant on public.staff_teachable_subject (tenant_id);

create trigger staff_teachable_subject_audit after insert or update or delete on public.staff_teachable_subject
  for each row execute function app.tg_audit_row();

-- Records a Principal-tier grant of a scope violation on a SPECIFIC
-- timetable_slot write (never a standing exemption) — matches the AC's
-- own "temporary cover until replacement joins" framing.
create table public.teach_scope_override (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  assignment_type text not null,
  assignment_id   uuid not null,
  approved_by     uuid not null references public.app_user(user_id),
  reason          text not null,
  created_at      timestamptz not null default now(),
  constraint chk_override_assignment_type check (assignment_type in ('timetable_slot'))
);

create index idx_teach_scope_override_assignment on public.teach_scope_override (assignment_type, assignment_id);

create or replace function public.can_teach(p_staff_id uuid, p_subject_id uuid, p_class_level_id uuid, p_stream_id uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.staff_teachable_subject sts
      join public.class_level cl_target on cl_target.id = p_class_level_id
      join public.class_level cl_from on cl_from.id = sts.class_level_from_id
      join public.class_level cl_to on cl_to.id = sts.class_level_to_id
     where sts.staff_id = p_staff_id
       and sts.subject_id = p_subject_id
       and cl_target.ordinal between cl_from.ordinal and cl_to.ordinal
       and (sts.stream_id is null or sts.stream_id = p_stream_id)
  );
$$;

revoke execute on function public.can_teach(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.can_teach(uuid, uuid, uuid, uuid) to authenticated;

create or replace function public.create_staff_teachable_subject(
  p_staff_id uuid,
  p_subject_id uuid,
  p_class_level_from_id uuid,
  p_class_level_to_id uuid,
  p_stream_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id    uuid := app.auth_tenant_id();
  v_from_ordinal smallint;
  v_to_ordinal   smallint;
  v_id           uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = v_tenant_id) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_from_ordinal from public.class_level where id = p_class_level_from_id and tenant_id = v_tenant_id;
  select ordinal into v_to_ordinal from public.class_level where id = p_class_level_to_id and tenant_id = v_tenant_id;
  if v_from_ordinal is null or v_to_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_from_ordinal > v_to_ordinal then
    raise exception 'GRADE_RANGE_INVALID' using errcode = '23514';
  end if;

  insert into public.staff_teachable_subject (tenant_id, staff_id, subject_id, class_level_from_id, class_level_to_id, stream_id)
  values (v_tenant_id, p_staff_id, p_subject_id, p_class_level_from_id, p_class_level_to_id, p_stream_id)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_staff_teachable_subject(uuid, uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.create_staff_teachable_subject(uuid, uuid, uuid, uuid, uuid) to authenticated;

-- AC: revoking never touches timetable_slot rows that already reference
-- the grant — they surface on v_teach_scope_exception instead.
create or replace function public.revoke_staff_teachable_subject(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.staff_teachable_subject where id = p_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'TEACHABLE_GRANT_NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.staff_teachable_subject where id = p_id;
end;
$$;

revoke execute on function public.revoke_staff_teachable_subject(uuid) from public, anon;
grant execute on function public.revoke_staff_teachable_subject(uuid) to authenticated;

create or replace view public.v_teach_scope_exception with (security_invoker = true) as
select
  ts.id as slot_id,
  ts.tenant_id,
  ts.campus_id,
  ts.timetable_version_id,
  ts.section_id,
  ts.staff_id,
  ts.subject_id,
  ts.weekday,
  ts.period_no
from public.timetable_slot ts
join public.class_section cs on cs.id = ts.section_id
where ts.staff_id is not null
  and not exists (
    select 1 from public.teach_scope_override o
     where o.assignment_type = 'timetable_slot' and o.assignment_id = ts.id
  )
  and not public.can_teach(ts.staff_id, ts.subject_id, cs.class_level_id, cs.stream_id);

alter table public.staff_teachable_subject enable row level security;
alter table public.teach_scope_override enable row level security;

create policy teachable_campus_scope on public.staff_teachable_subject
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy teach_scope_override_campus_scope on public.teach_scope_override
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- ── extend upsert_timetable_slot() with the teach-scope check ───────────
-- A new trailing parameter is a different signature to Postgres, not a
-- replacement — create or replace alone would leave the old 10-arg
-- overload reachable (and silently skipping the new check) alongside
-- this one. Drop it explicitly first.

drop function if exists public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text);

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

  if p_staff_id is not null and not public.can_teach(p_staff_id, p_subject_id, v_class_level_id, v_stream_id) then
    if p_override_reason is null or btrim(p_override_reason) = '' then
      raise exception 'TEACH_SCOPE_VIOLATION' using errcode = '23514';
    end if;
  end if;

  if p_staff_id is not null then
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
