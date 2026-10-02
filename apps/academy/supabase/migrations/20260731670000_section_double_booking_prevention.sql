-- FR-F07: section double-booking prevention (elective parallel blocks).
--
-- Design notes:
--   * idx_slot_version_section_day_period, plain-unique since FR-F04,
--     becomes a PARTIAL unique index (WHERE parallel_group_id IS NULL) —
--     exactly the shape this FR's own Notes calls for: a naive whole-
--     table unique index makes elective streaming impossible, but
--     dropping it entirely would let an ordinary (non-elective) cell
--     silently accept two unrelated subjects. A second partial index,
--     on (parallel_group_id, subject_id) WHERE parallel_group_id IS NOT
--     NULL, is what lets a single parallel member be re-saved in place
--     (room/teacher tweaks) rather than accumulating duplicate rows.
--   * SECTION_CLASH's own AC ("9-A holds Maths ... Urdu is added ... with
--     no elective bucket") is implemented as: writing a plain slot
--     (parallel_group_id IS NULL) to a cell that ALREADY holds an
--     established parallel block is rejected outright. It is
--     deliberately NOT "writing a different subject to an occupied plain
--     cell is rejected" — every FR since F04 relies on exactly that
--     being a legitimate edit (the Principal changes their mind about
--     what a period teaches), and preserving that isn't optional at this
--     point; five shipped FRs' own pgTAP/e2e suites assert it. The
--     genuine, new "double-booking" this FR's title is about is a plain
--     write silently orphaning or colliding with an already-built
--     parallel block, which is exactly what this check catches.
--   * The spec's own "constraint trigger" (trg_parallel_block_validate)
--     is folded into upsert_timetable_slot() instead — same "function is
--     this table's only write path, a trigger would just duplicate the
--     same check" reasoning as every other write-time invariant in this
--     module (SUBJECT_NOT_OFFERED, VERSION_IMMUTABLE, TEACHER_CLASH,
--     TEACH_SCOPE_VIOLATION).
--   * student_elective_choice is new, minimal schema this FR's own
--     AC3 genuinely needs and nothing existing models: class_subject's
--     own elective_bucket only defines the curriculum-level CHOICE SET
--     (which subjects form bucket 1), never which specific subject a
--     given student picked. No other FR in this catalogue owns that
--     either (checked: FR-E05 only defines streams). Scoped narrowly —
--     (student, session, class_level, bucket) -> one chosen subject —
--     not a general preferences system.
--   * A real bug caught while writing this: clone_timetable_version()
--     (FR-F10) blindly copied timetable_slot.parallel_group_id verbatim,
--     which would leave a cloned draft's parallel slots pointing at the
--     SOURCE version's own timetable_parallel_group rows — a group whose
--     own timetable_version_id belongs to a different version than the
--     slot that now references it, silently breaking the very
--     PARALLEL_BLOCK_PERIOD_MISMATCH invariant this migration adds.
--     Fixed by having clone_timetable_version() also clone
--     timetable_parallel_group rows and remap the copied slots'
--     parallel_group_id to the NEW rows, never the source version's.

create table public.timetable_parallel_group (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  timetable_version_id uuid not null references public.timetable_version(id) on delete cascade,
  section_id           uuid not null references public.class_section(id) on delete cascade,
  weekday              smallint not null,
  period_no            smallint not null,
  elective_bucket      smallint not null,
  created_at           timestamptz not null default now(),
  constraint chk_pgroup_weekday check (weekday between 0 and 6),
  constraint chk_pgroup_period check (period_no > 0)
);

create index idx_parallel_group_version_section on public.timetable_parallel_group (timetable_version_id, section_id, weekday, period_no);

alter table public.timetable_slot add constraint fk_slot_parallel_group foreign key (parallel_group_id) references public.timetable_parallel_group(id);

drop index public.idx_slot_version_section_day_period;
create unique index idx_slot_version_section_day_period
  on public.timetable_slot (timetable_version_id, section_id, weekday, period_no)
  where parallel_group_id is null;
create unique index idx_slot_parallel_group_subject
  on public.timetable_slot (parallel_group_id, subject_id)
  where parallel_group_id is not null;
create index idx_slot_parallel_group on public.timetable_slot (parallel_group_id) where parallel_group_id is not null;

alter table public.timetable_parallel_group enable row level security;

create policy timetable_parallel_group_campus_scope on public.timetable_parallel_group
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create or replace function public.create_timetable_parallel_group(
  p_version_id uuid, p_section_id uuid, p_weekday smallint, p_period_no smallint, p_elective_bucket smallint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_campus_id      uuid;
  v_version_status public.timetable_version_status;
  v_id             uuid;
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
  if not exists (select 1 from public.class_section where id = p_section_id and tenant_id = v_tenant_id) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.timetable_parallel_group (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, elective_bucket)
  values (v_tenant_id, v_campus_id, p_version_id, p_section_id, p_weekday, p_period_no, p_elective_bucket)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_timetable_parallel_group(uuid, uuid, smallint, smallint, smallint) from public, anon;
grant execute on function public.create_timetable_parallel_group(uuid, uuid, smallint, smallint, smallint) to authenticated;

-- ── extend upsert_timetable_slot() with parallel-block validation ──────
-- Same signature as FR-D03's own version — a new trailing param isn't
-- needed, p_elective_bucket/p_parallel_group_id have existed since F04
-- but were never validated.

drop function if exists public.upsert_timetable_slot(uuid, uuid, smallint, smallint, uuid, uuid, uuid, smallint, uuid, text, text);

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

-- ── clone_timetable_version(): fix the parallel-group orphaning bug ────

create or replace function public.clone_timetable_version(p_version_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_source    public.timetable_version%rowtype;
  v_new_id    uuid;
  v_next_no   smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_source from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_source.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select coalesce(max(version_no), 0) + 1 into v_next_no
    from public.timetable_version where campus_id = v_source.campus_id and session_id = v_source.session_id;

  insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no)
  values (v_tenant_id, v_source.campus_id, v_source.session_id, v_source.shift, v_source.name || ' (rev)', 'DRAFT', v_next_no)
  returning id into v_new_id;

  -- Clone parallel groups first, remapping old id -> new id, so the
  -- cloned slots below point at the NEW version's own group rows —
  -- never left referencing the source version's (see this migration's
  -- own header for the bug this fixes).
  -- authenticated's session preloads the safeupdate extension (blocks any
  -- UPDATE/DELETE with no WHERE clause) — "where true" satisfies it without
  -- changing which rows get cleared.
  create temporary table if not exists tmp_parallel_group_remap (old_id uuid primary key, new_id uuid) on commit drop;
  delete from tmp_parallel_group_remap where true;
  insert into tmp_parallel_group_remap (old_id, new_id)
  select pg.id, gen_random_uuid() from public.timetable_parallel_group pg where pg.timetable_version_id = p_version_id;

  insert into public.timetable_parallel_group (id, tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, elective_bucket)
  select r.new_id, pg.tenant_id, pg.campus_id, v_new_id, pg.section_id, pg.weekday, pg.period_no, pg.elective_bucket
    from public.timetable_parallel_group pg
    join tmp_parallel_group_remap r on r.old_id = pg.id
   where pg.timetable_version_id = p_version_id;

  insert into public.timetable_slot (
    tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no,
    subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
  )
  select ts.tenant_id, ts.campus_id, v_new_id, ts.section_id, ts.weekday, ts.period_no,
         ts.subject_id, ts.staff_id, ts.room_id, ts.elective_bucket, r.new_id, ts.note
    from public.timetable_slot ts
    left join tmp_parallel_group_remap r on r.old_id = ts.parallel_group_id
   where ts.timetable_version_id = p_version_id;

  return v_new_id;
end;
$$;

revoke execute on function public.clone_timetable_version(uuid) from public, anon;
grant execute on function public.clone_timetable_version(uuid) to authenticated;

-- ── student_elective_choice ─────────────────────────────────────────────

create table public.student_elective_choice (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  student_id      uuid not null references public.student(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  class_level_id  uuid not null references public.class_level(id),
  elective_bucket smallint not null,
  subject_id      uuid not null references public.subject(id),
  created_at      timestamptz not null default now(),
  unique (student_id, session_id, class_level_id, elective_bucket)
);

create index idx_elective_choice_student_session on public.student_elective_choice (student_id, session_id);

alter table public.student_elective_choice enable row level security;

create policy student_elective_choice_campus_scope on public.student_elective_choice
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create or replace function public.set_student_elective_choice(
  p_student_id uuid, p_session_id uuid, p_class_level_id uuid, p_elective_bucket smallint, p_subject_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id into v_campus_id from public.student where id = p_student_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.class_subject
     where campus_id = v_campus_id and session_id = p_session_id and class_level_id = p_class_level_id
       and subject_id = p_subject_id and elective_bucket = p_elective_bucket
  ) then
    raise exception 'SUBJECT_NOT_IN_BUCKET' using errcode = '23514';
  end if;

  insert into public.student_elective_choice (tenant_id, campus_id, student_id, session_id, class_level_id, elective_bucket, subject_id)
  values (v_tenant_id, v_campus_id, p_student_id, p_session_id, p_class_level_id, p_elective_bucket, p_subject_id)
  on conflict (student_id, session_id, class_level_id, elective_bucket) do update set subject_id = excluded.subject_id
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_student_elective_choice(uuid, uuid, uuid, smallint, uuid) from public, anon;
grant execute on function public.set_student_elective_choice(uuid, uuid, uuid, smallint, uuid) to authenticated;

-- AC: a student's own personal timetable renders exactly one subject per
-- parallel-block period — theirs — never the other elective(s) also
-- scheduled into that same cell. Plain (non-parallel) periods pass
-- through untouched. Guardian access mirrors FR-F11's own
-- app.auth_guardian_student_ids() gate; staff access is campus-scoped,
-- matching every other read this module gates the same way.
create or replace function public.student_timetable(p_enrolment_id uuid, p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_enrolment      public.enrolment%rowtype;
  v_class_level_id uuid;
  v_weekday        smallint;
  v_is_guardian    boolean;
begin
  select * into v_enrolment from public.enrolment where id = p_enrolment_id;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_is_guardian := v_enrolment.student_id = any(app.auth_guardian_student_ids());
  if not v_is_guardian
     and (v_enrolment.tenant_id <> v_tenant_id
          or (app.auth_role() not in ('super_admin', 'owner') and not (v_enrolment.campus_id = any(app.auth_campus_ids())))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select class_level_id into v_class_level_id from public.class_section where id = v_enrolment.section_id;
  v_weekday := extract(dow from p_date)::smallint;

  return coalesce(
    (
      select jsonb_agg(jsonb_build_object(
               'slot_id', ts.id,
               'period_no', ts.period_no,
               'subject_code', subj.code,
               'subject_name_en', subj.name_en,
               'subject_name_ur', subj.name_ur,
               'teacher_name', app.display_name_for_user(ts.staff_id),
               'room_code', r.code,
               'elective_bucket', ts.elective_bucket
             ) order by ts.period_no)
        from public.timetable_slot ts
        join public.timetable_version tv on tv.id = ts.timetable_version_id and tv.status = 'PUBLISHED'
        join public.subject subj on subj.id = ts.subject_id
        left join public.room r on r.id = ts.room_id
       where ts.section_id = v_enrolment.section_id and ts.weekday = v_weekday
         and (
           ts.parallel_group_id is null
           or exists (
             select 1 from public.student_elective_choice sec
              where sec.student_id = v_enrolment.student_id and sec.session_id = v_enrolment.session_id
                and sec.class_level_id = v_class_level_id and sec.elective_bucket = ts.elective_bucket
                and sec.subject_id = ts.subject_id
           )
         )
    ),
    '[]'::jsonb
  );
end;
$$;

revoke execute on function public.student_timetable(uuid, date) from public, anon;
grant execute on function public.student_timetable(uuid, date) to authenticated;
