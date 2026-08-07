-- FR-F10 (timetable version lifecycle) and FR-F09 (publish validation
-- gate), shipped together: F10's own AC1 ("version 3 is Published
-- effective 2026-08-01") presupposes a working publish action, and F09's
-- own Supabase Objects spec is the only place that action is defined
-- (publish_timetable). Building F10's schema alone would leave every one
-- of its own ACs unreachable — the same "the blocked FR needs the
-- blocking FR's own machinery to be testable at all" reasoning already
-- applied to D10/D11 and F04/F05 earlier this session.
--
-- Design notes:
--   * timetable_version_status: 'ARCHIVED' (F04's own placeholder, never
--     actually reached by any function) is renamed to 'SUPERSEDED' —
--     F10's own spec's third state. Grepped first: no other migration or
--     UI file references the literal string 'ARCHIVED', so this is a
--     rename, not an addition.
--   * validity is a generated, stored daterange, NULL while
--     effective_from is NULL (an unpublished DRAFT has no effective
--     range yet) — `case when effective_from is null then null else
--     daterange(...) end` rather than letting daterange(null, null)
--     silently produce an unbounded range that would then vacuously
--     collide with everything under the exclusion constraint.
--   * Supersession is explicit, not left to the exclusion constraint to
--     discover: publish_timetable() finds the campus/session's currently
--     open PUBLISHED version (effective_to IS NULL) and closes it
--     (effective_to = new effective_from - 1, status = SUPERSEDED) in the
--     same transaction, matching AC2's own literal wording, before
--     opening the new one. The exclusion constraint (ex_published_
--     version_no_overlap) is the backstop for a genuinely conflicting
--     publish this supersession logic doesn't cover — e.g. backdating a
--     new version's effective_from into an already-published range —
--     surfaced as VERSION_RANGE_OVERLAP (AC4).
--   * trg_block_published_slot_write (the spec's own trigger) is not
--     built: upsert_timetable_slot()/clear_timetable_slot() already
--     raise VERSION_IMMUTABLE for any non-DRAFT status (added in F04,
--     unchanged here) and are this table's only write path — a trigger
--     would duplicate that check with no additional coverage, the same
--     reasoning as every other function-gated write this module uses.
--   * "0 errors and 12 warnings... succeeds, warning_count = 12 stored"
--     (AC2) is a second, non-blocking category distinct from
--     QUOTA_SHORTFALL (which blocks). Nothing in either FR's Supabase
--     Objects defines what a "warning" is beyond this one AC line, so
--     it's scoped narrowly and defensibly to what's already inspectable
--     without new schema: a scheduled slot with no teacher assigned.
--     That's a real, useful heads-up ("this timetable is structurally
--     complete but N periods have nobody teaching them yet") that never
--     blocks, unlike a genuine quota shortfall.
--   * Quota validation only ever checks class_subject rows for class
--     levels/streams that actually have at least one class_section in
--     this version's campus/session — a class_subject requirement for a
--     stream nobody has sectioned this session can't be a real shortfall.

alter type public.timetable_version_status rename value 'ARCHIVED' to 'SUPERSEDED';

alter table public.timetable_version
  add column version_no smallint,
  add column effective_from date,
  add column effective_to date,
  add column published_by uuid references public.app_user(user_id),
  add column warning_count int not null default 0,
  add column validity daterange generated always as (
    case when effective_from is null then null else daterange(effective_from, effective_to, '[]') end
  ) stored;

create index idx_version_campus_session_status on public.timetable_version (campus_id, session_id, status);
create index idx_version_validity on public.timetable_version using gist (validity);

-- Backfills existing DRAFT rows (F04/F05/D03/D13's own prerequisite data)
-- with a version_no so the column can be not-null going forward without a
-- separate migration pass.
with numbered as (
  select id, row_number() over (partition by campus_id, session_id order by created_at) as rn
  from public.timetable_version
)
update public.timetable_version tv set version_no = numbered.rn
from numbered where numbered.id = tv.id;

alter table public.timetable_version alter column version_no set not null;

alter table public.timetable_version
  add constraint ex_published_version_no_overlap
  exclude using gist (campus_id with =, session_id with =, validity with &&)
  where (status = 'PUBLISHED');

-- Same signature as F04's own version — create-or-replace only, that
-- original migration file is untouched. version_no is now not-null, so
-- the function that creates the very first draft of a campus/session's
-- timetable has to assign it, the same next-number logic
-- clone_timetable_version() below uses for a revision.
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
  v_next_no   smallint;
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

  select coalesce(max(version_no), 0) + 1 into v_next_no
    from public.timetable_version where campus_id = p_campus_id and session_id = p_session_id;

  insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, version_no)
  values (v_tenant_id, p_campus_id, p_session_id, p_shift, p_name, v_next_no)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_timetable_version(uuid, uuid, public.section_shift, text) from public, anon;
grant execute on function public.create_timetable_version(uuid, uuid, public.section_shift, text) to authenticated;

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

  insert into public.timetable_slot (
    tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no,
    subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
  )
  select tenant_id, campus_id, v_new_id, section_id, weekday, period_no, subject_id, staff_id, room_id, elective_bucket, parallel_group_id, note
    from public.timetable_slot where timetable_version_id = p_version_id;

  return v_new_id;
end;
$$;

revoke execute on function public.clone_timetable_version(uuid) from public, anon;
grant execute on function public.clone_timetable_version(uuid) to authenticated;

-- AC3: which version's slots were actually in force for a given date.
-- Deliberately matches SUPERSEDED as well as PUBLISHED — a superseded
-- version's own validity range is exactly its historical window, and the
-- AC's own point is that attendance from that window must keep resolving
-- to it after a later version supersedes it. DRAFT rows have a NULL
-- validity (never published), so they can never match `@>` regardless.
create or replace function public.resolve_timetable_version(p_campus_id uuid, p_session_id uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.timetable_version
   where campus_id = p_campus_id and session_id = p_session_id and tenant_id = app.auth_tenant_id()
     and status in ('PUBLISHED', 'SUPERSEDED') and validity @> p_date
   limit 1;
$$;

revoke execute on function public.resolve_timetable_version(uuid, uuid, date) from public, anon;
grant execute on function public.resolve_timetable_version(uuid, uuid, date) to authenticated;

-- FR-F09: how many periods a (section, subject) requires vs how many this
-- version actually schedules. A class_subject row with stream_id null
-- applies to every stream at that class level (same convention
-- upsert_timetable_slot's own SUBJECT_NOT_OFFERED check already uses).
create or replace view public.v_scheduled_vs_required_periods with (security_invoker = true) as
select
  tv.id as timetable_version_id,
  cs_sec.id as section_id,
  cs_sec.name as section_name,
  csub.subject_id,
  subj.code as subject_code,
  csub.weekly_periods as required_periods,
  count(ts.id) as scheduled_periods
from public.timetable_version tv
join public.class_section cs_sec on cs_sec.campus_id = tv.campus_id and cs_sec.session_id = tv.session_id and cs_sec.is_active
join public.class_subject csub
  on csub.campus_id = tv.campus_id and csub.session_id = tv.session_id and csub.class_level_id = cs_sec.class_level_id
 and (csub.stream_id is null or csub.stream_id = cs_sec.stream_id)
join public.subject subj on subj.id = csub.subject_id
left join public.timetable_slot ts
  on ts.timetable_version_id = tv.id and ts.section_id = cs_sec.id and ts.subject_id = csub.subject_id
group by tv.id, cs_sec.id, cs_sec.name, csub.subject_id, subj.code, csub.weekly_periods;

create table public.timetable_publish_exception (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  timetable_version_id uuid not null references public.timetable_version(id) on delete cascade,
  section_id        uuid not null references public.class_section(id) on delete cascade,
  subject_id        uuid not null references public.subject(id),
  required_periods  smallint not null,
  scheduled_periods smallint not null,
  reason            text not null,
  created_by        uuid references public.app_user(user_id),
  created_at        timestamptz not null default now()
);

create index idx_publish_exception_version on public.timetable_publish_exception (timetable_version_id);

alter table public.timetable_publish_exception enable row level security;

create policy publish_exception_campus_scope on public.timetable_publish_exception
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.timetable_version tv
       where tv.id = timetable_publish_exception.timetable_version_id
         and (app.auth_role() in ('super_admin', 'owner') or tv.campus_id = any(app.auth_campus_ids()))
    )
  );

create or replace function public.publish_timetable(
  p_version_id uuid, p_effective_from date, p_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_version    public.timetable_version%rowtype;
  v_summary    text;
  v_warnings   int;
  v_prior_id   uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_version from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_version.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_version.status <> 'DRAFT' then
    raise exception 'VERSION_NOT_DRAFT' using errcode = '55000';
  end if;

  select string_agg(v.section_name || ' ' || v.subject_code || ' ' || v.scheduled_periods || '/' || v.required_periods, ', ' order by v.section_name, v.subject_code)
    into v_summary
    from public.v_scheduled_vs_required_periods v
   where v.timetable_version_id = p_version_id and v.scheduled_periods < v.required_periods;

  if v_summary is not null then
    if p_override_reason is null or length(btrim(p_override_reason)) < 10 then
      raise exception 'QUOTA_SHORTFALL: %', v_summary using errcode = '23514';
    end if;

    insert into public.timetable_publish_exception (
      tenant_id, timetable_version_id, section_id, subject_id, required_periods, scheduled_periods, reason, created_by
    )
    select v_tenant_id, p_version_id, v.section_id, v.subject_id, v.required_periods, v.scheduled_periods, p_override_reason, auth.uid()
      from public.v_scheduled_vs_required_periods v
     where v.timetable_version_id = p_version_id and v.scheduled_periods < v.required_periods;
  end if;

  select count(*)::int into v_warnings from public.timetable_slot where timetable_version_id = p_version_id and staff_id is null;

  -- AC2: close out whichever version is currently open (effective_to
  -- IS NULL) for this campus/session before opening this one — the
  -- ordinary "publish the next revision" path never needs the exclusion
  -- constraint to do this for it. Only a genuinely later effective_from is
  -- a valid "next revision" — backdating ahead of (or into) the currently
  -- open version's own start is a real conflict, not a supersession, so
  -- it's left alone here and falls through to the exclusion constraint
  -- below instead (AC4: VERSION_RANGE_OVERLAP).
  select id into v_prior_id from public.timetable_version
   where campus_id = v_version.campus_id and session_id = v_version.session_id and status = 'PUBLISHED' and effective_to is null
     and id <> p_version_id and effective_from < p_effective_from;
  if v_prior_id is not null then
    update public.timetable_version set status = 'SUPERSEDED', effective_to = p_effective_from - 1 where id = v_prior_id;
  end if;

  begin
    update public.timetable_version
       set status = 'PUBLISHED', effective_from = p_effective_from, effective_to = null,
           published_by = auth.uid(), published_at = clock_timestamp(), warning_count = v_warnings
     where id = p_version_id;
  exception
    when exclusion_violation then
      raise exception 'VERSION_RANGE_OVERLAP' using errcode = '23P01';
  end;

  return p_version_id;
end;
$$;

revoke execute on function public.publish_timetable(uuid, date, text) from public, anon;
grant execute on function public.publish_timetable(uuid, date, text) to authenticated;
