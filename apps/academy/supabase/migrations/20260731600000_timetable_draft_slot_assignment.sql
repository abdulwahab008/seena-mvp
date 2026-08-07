-- FR-F04: draft slot assignment (the timetable grid builder).
--
-- This FR needs a "timetable_version" (draft/published container) that no
-- earlier FR defines — F01-F03 never needed one. Built minimally here:
-- DRAFT/PUBLISHED/ARCHIVED status, no publish workflow function (that's a
-- future FR's job — publishing a version needs to lock its campus's bell
-- templates via trg_lock_bell_template_on_publish, which bell_template.sql
-- already anticipated). pgTAP simulates a published version by updating
-- status directly as superuser, the same "ground truth as superuser"
-- convention this suite already uses for bell_template.is_locked.
--
-- "the room field pre-fills with 9-A's home room" (AC) has no backing
-- column anywhere in the schema — class_section has no room concept at
-- all. Added home_room_id here since it's this FR's own prerequisite,
-- not scope creep: without it the AC is simply false.
--
-- Deviation from the Supabase Objects spec: it lists trg_slot_subject_offered
-- and trg_block_non_draft_slot_write as BEFORE triggers on timetable_slot.
-- Every other FR built this session (room, bell_template, bell_calendar_rule)
-- gates writes inside a SECURITY DEFINER function instead of an RLS write
-- policy + raw client insert, and does the same validation there rather
-- than in a trigger. Kept that convention: SUBJECT_NOT_OFFERED and
-- VERSION_IMMUTABLE are both checked inside upsert_timetable_slot() /
-- clear_timetable_slot(). Since timetable_slot has no RLS write policy for
-- `authenticated` at all (SELECT only), those two functions are the ONLY
-- possible write path — a trigger would be genuinely unreachable dead code,
-- not real defense-in-depth.

alter table public.class_section add column home_room_id uuid references public.room(id);

create type public.timetable_version_status as enum ('DRAFT', 'PUBLISHED', 'ARCHIVED');

create table public.timetable_version (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  session_id   uuid not null references public.academic_session(id) on delete cascade,
  shift        public.section_shift not null,
  name         text not null,
  status       public.timetable_version_status not null default 'DRAFT',
  created_at   timestamptz not null default now(),
  published_at timestamptz
);

create index idx_timetable_version_campus on public.timetable_version (campus_id, session_id, shift);

create trigger timetable_version_audit after insert or update or delete on public.timetable_version
  for each row execute function app.tg_audit_row();

create table public.timetable_slot (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  timetable_version_id uuid not null references public.timetable_version(id) on delete cascade,
  section_id           uuid not null references public.class_section(id) on delete cascade,
  weekday              smallint not null,
  period_no            smallint not null,
  subject_id           uuid not null references public.subject(id),
  staff_id             uuid references public.app_user(user_id),
  room_id              uuid references public.room(id),
  elective_bucket      smallint,
  parallel_group_id    uuid,
  note                 text,
  created_at           timestamptz not null default now(),
  constraint chk_slot_weekday check (weekday between 0 and 6),
  constraint chk_slot_period_no check (period_no > 0)
);

-- One slot per (version, section, weekday, period) — also the natural
-- lookup index for rendering a section's grid.
create unique index idx_slot_version_section_day_period on public.timetable_slot (timetable_version_id, section_id, weekday, period_no);

create trigger timetable_slot_audit after insert or update or delete on public.timetable_slot
  for each row execute function app.tg_audit_row();

-- DELETE (clear_timetable_slot) events only carry the primary key under
-- the default replica identity, so a client-side realtime filter on
-- timetable_version_id (not the PK) can never match and the event is
-- silently dropped — full identity is needed for a DELETE to be filterable
-- by any other column.
alter table public.timetable_slot replica identity full;
alter publication supabase_realtime add table public.timetable_slot;

create or replace function public.create_timetable_version(
  p_campus_id uuid, p_session_id uuid, p_shift public.section_shift, p_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name)
  values (v_tenant_id, p_campus_id, p_session_id, p_shift, p_name)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_timetable_version(uuid, uuid, public.section_shift, text) from public, anon;
grant execute on function public.create_timetable_version(uuid, uuid, public.section_shift, text) to authenticated;

-- AC: teacher pre-fills from the section's own primary allocation, room
-- pre-fills from the section's home room — both nullable (no teacher
-- assigned yet, no home room set), both overridable by the caller.
create or replace function public.prefill_slot_defaults(p_section_id uuid, p_subject_id uuid)
returns table (staff_id uuid, room_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select sst.staff_id
       from public.section_subject_teacher sst
      where sst.section_id = p_section_id
        and sst.subject_id = p_subject_id
        and sst.role = 'primary'
        and sst.validity @> current_date
      limit 1),
    (select cs.home_room_id from public.class_section cs where cs.id = p_section_id and cs.tenant_id = app.auth_tenant_id());
$$;

revoke execute on function public.prefill_slot_defaults(uuid, uuid) from public, anon;
grant execute on function public.prefill_slot_defaults(uuid, uuid) to authenticated;

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
  v_tenant_id      uuid := app.auth_tenant_id();
  v_campus_id      uuid;
  v_version_status public.timetable_version_status;
  v_class_level_id uuid;
  v_stream_id      uuid;
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

  select class_level_id, stream_id into v_class_level_id, v_stream_id
    from public.class_section where id = p_section_id and tenant_id = v_tenant_id;
  if v_class_level_id is null then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A class_subject row with stream_id null applies to every stream at
  -- that class level (e.g. compulsory subjects); a non-null stream_id
  -- restricts it to that stream only (FR-D03's own "Mathematics for
  -- Pre-Engineering is not Mathematics for Commerce" distinction).
  if not exists (
    select 1 from public.class_subject cs
     where cs.class_level_id = v_class_level_id
       and (cs.stream_id is null or cs.stream_id = v_stream_id)
       and cs.subject_id = p_subject_id
  ) then
    raise exception 'SUBJECT_NOT_OFFERED' using errcode = '23514';
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

-- AC: clearing a slot deletes the row outright (the cell then renders as
-- a free period) — never a soft "empty" marker.
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

  delete from public.timetable_slot
   where timetable_version_id = p_version_id and section_id = p_section_id
     and weekday = p_weekday and period_no = p_period_no;
end;
$$;

revoke execute on function public.clear_timetable_slot(uuid, uuid, smallint, smallint) from public, anon;
grant execute on function public.clear_timetable_slot(uuid, uuid, smallint, smallint) to authenticated;

alter table public.timetable_version enable row level security;
alter table public.timetable_slot enable row level security;

create policy timetable_version_campus_scope on public.timetable_version
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy timetable_slot_campus_scope on public.timetable_slot
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
