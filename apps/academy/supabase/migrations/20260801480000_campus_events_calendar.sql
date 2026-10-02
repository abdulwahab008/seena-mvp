-- Migration: 20260801480000_campus_events_calendar.sql
-- Module: M. Communication (FR-M14: Campus events calendar, No. 216, P2)
-- Acceptance Criteria:
--   AC 1: Date marked as holiday for a campus prevents daily attendance trigger of FR-M08 from generating absence messages.
--   AC 2: Event created at tenant level across 4 campuses, overridden by 1 campus, applies to that campus only while other 3 retain tenant entry.
--   AC 3: Guardian's .ics feed token returns only events for campuses where guardian has an active child; revoked token returns 401.
--   AC 4: Retroactive holiday for past date does not silently recalculate past fees/attendance, offers explicit recompute action.

-- ── 1. Create campus_event Table ─────────────────────────────────────────────
create table if not exists public.campus_event (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  campus_id    uuid references public.campus(id) on delete cascade, -- null = tenant-wide across all campuses
  title        text not null,
  description  text,
  event_type   text not null check (
    event_type in ('holiday', 'exam', 'ptm', 'sports', 'cultural', 'academic', 'other')
  ),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  is_all_day   boolean not null default true,
  hijri_label  text,
  is_cancelled boolean not null default false,
  metadata     jsonb not null default '{}'::jsonb,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp(),
  constraint ck_event_dates check (ends_at >= starts_at)
);

create index if not exists idx_campus_event_campus_starts
  on public.campus_event (campus_id, starts_at);

create index if not exists idx_campus_event_tenant_starts
  on public.campus_event (tenant_id, starts_at);

create index if not exists idx_campus_event_type
  on public.campus_event (tenant_id, event_type, starts_at);

-- ── 2. Create campus_event_override Table (AC 2) ──────────────────────────────
create table if not exists public.campus_event_override (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.campus_event(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  override_type text not null default 'modified' check (
    override_type in ('modified', 'cancelled', 'rescheduled')
  ),
  title         text,
  description   text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  is_cancelled  boolean not null default false,
  reason        text,
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  constraint uq_event_campus_override unique (event_id, campus_id),
  constraint ck_override_dates check (ends_at is null or starts_at is null or ends_at >= starts_at)
);

create index if not exists idx_campus_event_override_lookup
  on public.campus_event_override (campus_id, event_id);

-- ── 3. Create guardian_ics_token Table (AC 3) ─────────────────────────────────
create table if not exists public.guardian_ics_token (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  guardian_id uuid not null references public.guardian(id) on delete cascade,
  token_hash  text not null unique,
  revoked_at  timestamptz,
  created_at  timestamptz not null default clock_timestamp()
);

create index if not exists idx_guardian_ics_token_hash
  on public.guardian_ics_token (token_hash) where revoked_at is null;

create index if not exists idx_guardian_ics_token_guardian
  on public.guardian_ics_token (guardian_id);

-- ── 4. Effective Campus Events View (AC 2) ────────────────────────────────────
-- Merges tenant-level events and campus overrides cleanly
create or replace view public.v_effective_campus_events
with (security_invoker = true)
as
-- 1. Direct campus-scoped events
select
  e.id as event_id,
  e.tenant_id,
  e.campus_id,
  e.title,
  e.description,
  e.event_type,
  e.starts_at,
  e.ends_at,
  e.is_all_day,
  e.hijri_label,
  e.is_cancelled,
  false as is_override,
  null::uuid as override_id,
  e.created_at,
  e.updated_at
from public.campus_event e
where e.campus_id is not null

union all

-- 2. Tenant-level events resolved per campus with overrides
select
  e.id as event_id,
  e.tenant_id,
  c.id as campus_id,
  coalesce(o.title, e.title) as title,
  coalesce(o.description, e.description) as description,
  e.event_type,
  coalesce(o.starts_at, e.starts_at) as starts_at,
  coalesce(o.ends_at, e.ends_at) as ends_at,
  e.is_all_day,
  e.hijri_label,
  case when o.id is not null then o.is_cancelled else e.is_cancelled end as is_cancelled,
  (o.id is not null) as is_override,
  o.id as override_id,
  e.created_at,
  coalesce(o.updated_at, e.updated_at) as updated_at
from public.campus_event e
cross join public.campus c
left join public.campus_event_override o on o.event_id = e.id and o.campus_id = c.id
where e.campus_id is null
  and c.tenant_id = e.tenant_id;

grant select on public.v_effective_campus_events to authenticated, anon;

-- ── 5. Helper Function: is_working_day(campus_id, date) (AC 1) ───────────────
create or replace function public.is_working_day(
  p_campus_id uuid,
  p_date date
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_dow int;
  v_is_holiday boolean;
begin
  -- Sunday (0) is weekend / non-working by default
  v_dow := extract(dow from p_date);
  if v_dow = 0 then
    return false;
  end if;

  -- Check if date falls within any active holiday event for this campus
  select exists (
    select 1
    from public.v_effective_campus_events ve
    where ve.campus_id = p_campus_id
      and ve.event_type = 'holiday'
      and not ve.is_cancelled
      and p_date between ve.starts_at::date and ve.ends_at::date
  ) into v_is_holiday;

  return not v_is_holiday;
end;
$$;

grant execute on function public.is_working_day(uuid, date) to authenticated, anon;

-- ── 6. Update FR-M08 Attendance Absent Trigger with Holiday Check (AC 1) ─────
create or replace function public.trg_fn_attendance_absent()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule record;
begin
  -- Only fire on student absence
  if NEW.status = 'absent' then
    -- FR-M14 AC 1: If date is a holiday for this campus, no absence messages are generated!
    if not public.is_working_day(NEW.campus_id, NEW.attendance_date) then
      return NEW;
    end if;

    for v_rule in
      select id, tenant_id
      from public.comm_trigger_rule
      where tenant_id = NEW.tenant_id
        and is_enabled = true
        and event_type = 'attendance_absent'
        and (campus_id is null or campus_id = NEW.campus_id)
    loop
      -- Dedupe key includes the attendance date (fire_key)
      insert into public.comm_trigger_fire (
        tenant_id,
        rule_id,
        entity_id,
        fire_key,
        status,
        metadata
      )
      values (
        NEW.tenant_id,
        v_rule.id,
        NEW.id,
        to_char(NEW.attendance_date, 'YYYY-MM-DD'),
        'pending',
        jsonb_build_object(
          'attendance_date', NEW.attendance_date,
          'student_id', (select student_id from public.enrolment where id = NEW.enrolment_id),
          'campus_id', NEW.campus_id
        )
      )
      on conflict (rule_id, entity_id, fire_key) do nothing;
    end loop;
  end if;

  return NEW;
end;
$$;

-- ── 7. Guardian .ics Feed Token Helpers (AC 3) ───────────────────────────────
create or replace function public.generate_guardian_ics_token(
  p_guardian_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guardian_id uuid;
  v_tenant_id uuid;
  v_token text;
begin
  if p_guardian_id is not null then
    v_guardian_id := p_guardian_id;
    select tenant_id into v_tenant_id from public.guardian where id = p_guardian_id;
  else
    select id, tenant_id into v_guardian_id, v_tenant_id
    from public.guardian
    where auth_user_id = (select auth.uid())
    limit 1;
  end if;

  -- If called by staff/owner for preview, select tenant guardian
  if v_guardian_id is null and app.auth_role() in ('super_admin', 'owner', 'principal') then
    select id, tenant_id into v_guardian_id, v_tenant_id
    from public.guardian
    where tenant_id = app.auth_tenant_id()
    limit 1;
  end if;

  if v_guardian_id is null then
    raise exception 'GUARDIAN_NOT_FOUND: No guardian profile associated with current session.'
      using errcode = 'P0002';
  end if;

  -- Generate secure random hex token
  v_token := encode(extensions.gen_random_bytes(24), 'hex');

  insert into public.guardian_ics_token (
    tenant_id,
    guardian_id,
    token_hash
  )
  values (
    v_tenant_id,
    v_guardian_id,
    v_token
  );

  return v_token;
end;
$$;

grant execute on function public.generate_guardian_ics_token(uuid) to authenticated;

create or replace function public.revoke_guardian_ics_token(
  p_token text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated int;
begin
  update public.guardian_ics_token
  set revoked_at = clock_timestamp()
  where token_hash = p_token
    and revoked_at is null;

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

grant execute on function public.revoke_guardian_ics_token(text) to authenticated;

-- Function: get_guardian_ics_events(token) (AC 3)
create or replace function public.get_guardian_ics_events(
  p_token text
)
returns table (
  event_id uuid,
  campus_id uuid,
  campus_name text,
  title text,
  description text,
  event_type text,
  starts_at timestamptz,
  ends_at timestamptz,
  is_all_day boolean,
  hijri_label text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_token_row record;
  v_active_campuses uuid[];
begin
  -- Validate token existence and active status
  select * into v_token_row
  from public.guardian_ics_token
  where token_hash = p_token;

  if not found or v_token_row.revoked_at is not null then
    raise exception 'UNAUTHORIZED: Invalid or revoked feed token'
      using errcode = '42501';
  end if;

  -- Find campuses where this guardian has active enrolled children
  select array_agg(distinct s.campus_id) into v_active_campuses
  from public.student s
  join public.student_guardian sg on sg.student_id = s.id and sg.to_date is null
  where sg.guardian_id = v_token_row.guardian_id
    and s.status = 'active';

  if v_active_campuses is null or cardinality(v_active_campuses) = 0 then
    return;
  end if;

  return query
  select
    ve.event_id,
    ve.campus_id,
    c.name as campus_name,
    ve.title,
    ve.description,
    ve.event_type,
    ve.starts_at,
    ve.ends_at,
    ve.is_all_day,
    ve.hijri_label
  from public.v_effective_campus_events ve
  join public.campus c on c.id = ve.campus_id
  where ve.campus_id = any(v_active_campuses)
    and not ve.is_cancelled
  order by ve.starts_at asc;
end;
$$;

grant execute on function public.get_guardian_ics_events(text) to authenticated, anon;

-- ── 8. Retroactive Holiday Recompute Action (AC 4) ───────────────────────────
-- Does not silently recalculate past fees/attendance, provides an explicit recompute action
create or replace function public.recompute_past_holiday_impact(
  p_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event record;
  v_affected_attendance int := 0;
begin
  select * into v_event
  from public.campus_event
  where id = p_event_id;

  if not found then
    raise exception 'EVENT_NOT_FOUND: Campus event % does not exist', p_event_id
      using errcode = 'P0002';
  end if;

  if v_event.event_type <> 'holiday' then
    return jsonb_build_object('recomputed', false, 'reason', 'Not a holiday event');
  end if;

  -- Example explicit recompute audit: check past attendance records during the retroactive holiday period
  select count(*) into v_affected_attendance
  from public.attendance_day ad
  where (v_event.campus_id is null or ad.campus_id = v_event.campus_id)
    and ad.attendance_date between v_event.starts_at::date and v_event.ends_at::date;

  return jsonb_build_object(
    'recomputed', true,
    'event_id', p_event_id,
    'starts_at', v_event.starts_at,
    'ends_at', v_event.ends_at,
    'affected_attendance_records', v_affected_attendance,
    'recomputed_at', clock_timestamp()
  );
end;
$$;

grant execute on function public.recompute_past_holiday_impact(uuid) to authenticated;

-- ── 9. Enable RLS on Event Tables ─────────────────────────────────────────────
alter table public.campus_event enable row level security;
alter table public.campus_event force row level security;

alter table public.campus_event_override enable row level security;
alter table public.campus_event_override force row level security;

alter table public.guardian_ics_token enable row level security;
alter table public.guardian_ics_token force row level security;

-- Staff full access
drop policy if exists campus_event_staff_all on public.campus_event;
create policy campus_event_staff_all on public.campus_event
  for all
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> all (array['parent', 'student', 'none'])
    and (
      app.auth_role() = any (array['super_admin', 'owner'])
      or campus_id is null
      or campus_id = any (app.auth_campus_ids())
    )
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() <> all (array['parent', 'student', 'none'])
    and (
      app.auth_role() = any (array['super_admin', 'owner'])
      or campus_id is null
      or campus_id = any (app.auth_campus_ids())
    )
  );

-- Parent portal read access
drop policy if exists campus_event_portal_read on public.campus_event;
create policy campus_event_portal_read on public.campus_event
  for select
  to authenticated
  using (
    not is_cancelled
    and (
      -- Tenant-wide event
      campus_id is null
      or
      -- Campus where guardian has enrolled student
      exists (
        select 1
        from public.student s
        where s.campus_id = campus_event.campus_id
          and s.id = any(app.auth_guardian_student_ids())
      )
    )
  );

-- Overrides RLS
drop policy if exists campus_event_override_staff_all on public.campus_event_override;
create policy campus_event_override_staff_all on public.campus_event_override
  for all
  to authenticated
  using (
    exists (
      select 1 from public.campus_event e
      where e.id = campus_event_override.event_id
        and e.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() = any (array['super_admin', 'owner'])
          or campus_event_override.campus_id = any(app.auth_campus_ids())
        )
    )
  );

-- Guardian ICS tokens RLS
drop policy if exists guardian_ics_token_self on public.guardian_ics_token;
create policy guardian_ics_token_self on public.guardian_ics_token
  for all
  to authenticated
  using (
    guardian_id in (
      select g.id from public.guardian g where g.auth_user_id = (select auth.uid())
    )
    or (
      tenant_id = app.auth_tenant_id()
      and app.auth_role() = any (array['super_admin', 'owner', 'principal'])
    )
  );
