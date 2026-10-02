-- Migration: 20260801470000_circular_read_receipts.sql
-- Module: M. Communication (FR-M13)
-- Acceptance Criteria:
--   AC 1: Guardian opening same circular multiple times creates exactly 1 row; first_read_at unchanged.
--   AC 2: Stats view shows 'X of Y read (Z%)' and allows exporting unread list as a segment for follow-up.
--   AC 3: Guardian with multiple children in target segment is counted once, not multiple times.
--   AC 4: RLS prevents Guardian A from seeing whether Guardian B has read it.

-- ── 1. Create circular_read_receipt Table ───────────────────────────────────────
create table if not exists public.circular_read_receipt (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  circular_id   uuid not null references public.circular(id) on delete cascade,
  guardian_id   uuid not null references public.guardian(id) on delete cascade,
  first_read_at timestamptz not null default clock_timestamp(),
  metadata      jsonb not null default '{}'::jsonb,
  constraint uq_circular_read_receipt unique (circular_id, guardian_id)
);

create index if not exists idx_circular_read_receipt_circular
  on public.circular_read_receipt (circular_id);

create index if not exists idx_circular_read_receipt_guardian
  on public.circular_read_receipt (guardian_id);

create index if not exists idx_circular_read_receipt_tenant
  on public.circular_read_receipt (tenant_id);

-- ── 2. Enable RLS on circular_read_receipt ───────────────────────────────────
alter table public.circular_read_receipt enable row level security;
alter table public.circular_read_receipt force row level security;

-- Guardian can only read their own receipts
drop policy if exists receipt_self_read on public.circular_read_receipt;
create policy receipt_self_read on public.circular_read_receipt
  for select
  to authenticated
  using (
    guardian_id in (
      select g.id from public.guardian g where g.auth_user_id = (select auth.uid())
    )
  );

-- Publisher / Staff can view all receipts for circulars within their tenant/campus
drop policy if exists receipt_publisher_read on public.circular_read_receipt;
create policy receipt_publisher_read on public.circular_read_receipt
  for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin', 'teacher', 'staff', 'academic_coordinator'])
    )
  );

-- Guardian or Publisher can insert receipts (e.g. self-read recording)
drop policy if exists receipt_self_write on public.circular_read_receipt;
create policy receipt_self_write on public.circular_read_receipt
  for insert
  to authenticated
  with check (
    guardian_id in (
      select g.id from public.guardian g where g.auth_user_id = (select auth.uid())
    )
    or (
      tenant_id = app.auth_tenant_id()
      and app.auth_role() = any (array['super_admin', 'owner', 'principal', 'admin'])
    )
  );

-- ── 3. Helper Functions ────────────────────────────────────────────────────────
-- Helper to get auth guardian id
create or replace function app.auth_guardian_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.guardian where auth_user_id = (select auth.uid()) limit 1;
$$;

grant execute on function app.auth_guardian_id() to authenticated;

-- Function: mark_circular_read(circular_id, guardian_id)
-- Inserts a receipt if not already recorded. Preserves first_read_at on subsequent opens.
create or replace function public.mark_circular_read(
  p_circular_id uuid,
  p_guardian_id uuid default null
)
returns public.circular_read_receipt
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_guardian_id uuid;
  v_tenant_id uuid;
  v_receipt public.circular_read_receipt;
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

  if v_guardian_id is null then
    raise exception 'GUARDIAN_NOT_FOUND: No guardian profile associated with current session.'
      using errcode = 'P0002';
  end if;

  if v_tenant_id is null then
    select tenant_id into v_tenant_id from public.circular where id = p_circular_id;
  end if;

  -- Insert with ON CONFLICT DO NOTHING to strictly preserve first_read_at
  insert into public.circular_read_receipt (
    tenant_id,
    circular_id,
    guardian_id,
    first_read_at
  )
  values (
    coalesce(v_tenant_id, app.auth_tenant_id()),
    p_circular_id,
    v_guardian_id,
    clock_timestamp()
  )
  on conflict (circular_id, guardian_id) do nothing
  returning * into v_receipt;

  -- If conflict occurred, retrieve existing row
  if v_receipt.id is null then
    select * into v_receipt
    from public.circular_read_receipt
    where circular_id = p_circular_id
      and guardian_id = v_guardian_id;
  end if;

  return v_receipt;
end;
$$;

grant execute on function public.mark_circular_read(uuid, uuid) to authenticated;

-- Function: get distinct targeted guardians for a circular
create or replace function public.get_circular_targeted_guardians(p_circular_id uuid)
returns table (
  guardian_id uuid,
  tenant_id uuid,
  campus_id uuid,
  guardian_name text,
  phone_e164 text,
  alt_phone text
)
language sql
stable
security definer
set search_path = ''
as $$
  with circ as (
    select c.id, c.tenant_id, c.campus_id,
           exists(select 1 from public.circular_audience ca where ca.circular_id = c.id) as has_audience
    from public.circular c
    where c.id = p_circular_id
  )
  select distinct
    g.id as guardian_id,
    g.tenant_id,
    s.campus_id,
    g.name_en as guardian_name,
    g.phone_e164,
    g.alt_phone
  from circ
  cross join public.guardian g
  join public.student_guardian sg on sg.guardian_id = g.id and sg.to_date is null
  join public.student s on s.id = sg.student_id and s.status = 'active'
  where g.tenant_id = circ.tenant_id
    and (circ.campus_id is null or s.campus_id = circ.campus_id)
    and (
      -- Broadcast circular: all guardians with active students in tenant/campus
      not circ.has_audience
      or
      -- Targeted circular: guardian has at least one active child matching any of the circular segments
      exists (
        select 1
        from public.circular_audience ca
        where ca.circular_id = circ.id
          and public.student_matches_segment(s.id, ca.segment_id)
      )
    );
$$;

grant execute on function public.get_circular_targeted_guardians(uuid) to authenticated;

-- ── 4. Views for Read Stats & Unread Guardians ─────────────────────────────────
-- Unread guardians view (security_invoker)
create or replace view public.v_circular_unread_guardians
with (security_invoker = true)
as
select
  c.id as circular_id,
  tg.guardian_id,
  tg.guardian_name,
  tg.phone_e164,
  tg.alt_phone,
  tg.tenant_id,
  tg.campus_id
from public.circular c
cross join lateral public.get_circular_targeted_guardians(c.id) tg
where not exists (
  select 1
  from public.circular_read_receipt crr
  where crr.circular_id = c.id
    and crr.guardian_id = tg.guardian_id
);

-- Read stats view (security_invoker)
create or replace view public.v_circular_read_stats
with (security_invoker = true)
as
with target_counts as (
  select
    c.id as circular_id,
    count(distinct tg.guardian_id) as total_targeted_guardians
  from public.circular c
  left join lateral public.get_circular_targeted_guardians(c.id) tg on true
  group by c.id
),
read_counts as (
  select
    circular_id,
    count(distinct guardian_id) as read_guardians_count
  from public.circular_read_receipt
  group by circular_id
)
select
  c.id as circular_id,
  c.tenant_id,
  c.campus_id,
  c.title,
  c.status,
  c.publish_at,
  c.expires_at,
  coalesce(tc.total_targeted_guardians, 0)::bigint as total_targeted_guardians,
  coalesce(rc.read_guardians_count, 0)::bigint as read_guardians_count,
  greatest(coalesce(tc.total_targeted_guardians, 0) - coalesce(rc.read_guardians_count, 0), 0)::bigint as unread_guardians_count,
  case
    when coalesce(tc.total_targeted_guardians, 0) > 0
    then round((coalesce(rc.read_guardians_count, 0)::numeric / tc.total_targeted_guardians::numeric) * 100.0)
    else 0
  end as read_percentage,
  case
    when coalesce(tc.total_targeted_guardians, 0) > 0
    then coalesce(rc.read_guardians_count, 0)::text || ' of ' || tc.total_targeted_guardians::text || ' read (' ||
         round((coalesce(rc.read_guardians_count, 0)::numeric / tc.total_targeted_guardians::numeric) * 100.0)::text || '%)'
    else '0 of 0 read (0%)'
  end as formatted_stats
from public.circular c
left join target_counts tc on tc.circular_id = c.id
left join read_counts rc on rc.circular_id = c.id;

grant select on public.v_circular_unread_guardians to authenticated;
grant select on public.v_circular_read_stats to authenticated;

-- ── 5. Function to Export Unread Guardians as Segment (FR-M06 Integration) ────
create or replace function public.export_circular_unread_segment(
  p_circular_id uuid,
  p_segment_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_circ record;
  v_segment_id uuid;
begin
  select * into v_circ
  from public.circular
  where id = p_circular_id;

  if not found then
    raise exception 'CIRCULAR_NOT_FOUND: Circular % does not exist', p_circular_id
      using errcode = 'P0002';
  end if;

  insert into public.message_segment (
    tenant_id,
    campus_id,
    name,
    description,
    segment_type,
    definition,
    is_active
  )
  values (
    v_circ.tenant_id,
    v_circ.campus_id,
    p_segment_name,
    'Unread follow-up for circular: ' || v_circ.title,
    'custom_filter',
    jsonb_build_object(
      'filter_type', 'circular_unread',
      'circular_id', p_circular_id,
      'exported_at', clock_timestamp()
    ),
    true
  )
  returning id into v_segment_id;

  return v_segment_id;
end;
$$;

grant execute on function public.export_circular_unread_segment(uuid, text) to authenticated;

-- ── 6. Update resolve_segment to support circular_unread filter ───────────────
create or replace function public.resolve_segment(
  p_segment_id uuid,
  p_as_of date default current_date
)
returns table (
  student_id uuid,
  enrolment_id uuid,
  guardian_id uuid,
  student_name text,
  gr_number text,
  guardian_name text,
  guardian_phone text,
  dues_pkr numeric,
  attendance_status text,
  meta jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_segment record;
  v_min_dues_paisa bigint;
  v_exclude_hardship boolean;
  v_campus_cutoff time;
  v_cutoff_time time;
  v_enforce_cutoff boolean;
  v_check_time time := clock_timestamp()::time;
  v_circ_id uuid;
begin
  select id, tenant_id, campus_id, name, segment_type, definition
  into v_segment
  from public.message_segment
  where id = p_segment_id and is_active = true;

  if not found then
    raise exception 'Segment not found or inactive: %', p_segment_id using errcode = 'P0002';
  end if;

  -- ─── Segment Type: Fee Defaulters (AC 1) ──────────────────────────────────
  if v_segment.segment_type = 'defaulters' then
    v_min_dues_paisa := (coalesce((v_segment.definition->>'min_dues_pkr')::numeric, 5000) * 100)::bigint;
    v_exclude_hardship := coalesce((v_segment.definition->>'exclude_hardship')::boolean, true);

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      round(o.outstanding_paisa / 100.0, 2) as dues_pkr,
      null::text as attendance_status,
      jsonb_build_object(
        'outstanding_paisa', o.outstanding_paisa,
        'min_dues_pkr', round(v_min_dues_paisa / 100.0, 2),
        'enrolment_roll_no', e.roll_no,
        'has_hardship_waiver', false
      ) as meta
    from public.v_student_outstanding o
    join public.student s on s.id = o.student_id
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_financial desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where o.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or s.campus_id = v_segment.campus_id)
      and o.outstanding_paisa >= v_min_dues_paisa
      and coalesce(g.phone_e164, g.alt_phone) is not null
      and (
        not v_exclude_hardship
        or not exists (
          select 1
          from public.fee_waiver fw
          where fw.student_id = s.id
            and fw.category = 'hardship'
            and fw.status = 'approved'
            and (fw.valid_until is null or fw.valid_until >= p_as_of)
        )
      );

  -- ─── Segment Type: Absent Today (AC 2 & Cutoff Check) ────────────────────
  elsif v_segment.segment_type = 'absent_today' then
    v_enforce_cutoff := coalesce((v_segment.definition->>'enforce_cutoff')::boolean, true);

    if v_segment.campus_id is not null then
      select absentee_cutoff_time into v_campus_cutoff
      from public.campus_message_settings
      where campus_id = v_segment.campus_id and tenant_id = v_segment.tenant_id;
    end if;

    v_cutoff_time := coalesce(
      (v_segment.definition->>'cutoff_time')::time,
      v_campus_cutoff,
      '09:30:00'::time
    );

    if v_enforce_cutoff and v_check_time < v_cutoff_time and p_as_of = current_date then
      return;
    end if;

    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      ad.status::text as attendance_status,
      jsonb_build_object(
        'attendance_date', ad.attendance_date,
        'marked_at', ad.marked_at,
        'corrected', ad.corrected,
        'attendance_status', ad.status,
        'cutoff_time', v_cutoff_time
      ) as meta
    from public.attendance_day ad
    join public.enrolment e on e.id = ad.enrolment_id
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_academic desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where ad.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or ad.campus_id = v_segment.campus_id)
      and ad.attendance_date = p_as_of
      and ad.status = 'absent'
      and e.status = 'active'
      and s.status = 'active'
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Segment Type: Circular Unread Export (FR-M13 AC 2) ───────────────────
  elsif v_segment.segment_type = 'custom_filter' and (v_segment.definition->>'filter_type') = 'circular_unread' then
    v_circ_id := (v_segment.definition->>'circular_id')::uuid;

    return query
    select distinct on (ug.guardian_id)
      s.id as student_id,
      e.id as enrolment_id,
      ug.guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      ug.guardian_name,
      coalesce(ug.phone_e164, ug.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'unread'::text as attendance_status,
      jsonb_build_object('circular_id', v_circ_id, 'reason', 'unread_circular_follow_up') as meta
    from public.v_circular_unread_guardians ug
    join public.student_guardian sg on sg.guardian_id = ug.guardian_id and sg.to_date is null
    join public.student s on s.id = sg.student_id and s.status = 'active'
    join public.enrolment e on e.student_id = s.id and e.status = 'active'
    where ug.circular_id = v_circ_id
      and coalesce(ug.phone_e164, ug.alt_phone) is not null
    order by ug.guardian_id, sg.is_primary desc;

  -- ─── Generic / Class Level Segment ────────────────────────────────────────
  else
    return query
    select
      s.id as student_id,
      e.id as enrolment_id,
      g.id as guardian_id,
      s.name_en as student_name,
      s.gr_number as gr_number,
      coalesce(g.name_en, 'Parent of ' || s.name_en) as guardian_name,
      coalesce(g.phone_e164, g.alt_phone) as guardian_phone,
      0::numeric as dues_pkr,
      'enrolled'::text as attendance_status,
      jsonb_build_object('class_level_id', e.class_level_id, 'section_id', e.section_id) as meta
    from public.enrolment e
    join public.student s on s.id = e.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where e.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or e.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and (
        v_segment.definition->>'class_level_id' is null
        or e.class_level_id = (v_segment.definition->>'class_level_id')::uuid
      )
      and (
        v_segment.definition->>'section_id' is null
        or e.section_id = (v_segment.definition->>'section_id')::uuid
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;
  end if;
end;
$$;

grant execute on function public.resolve_segment(uuid, date) to authenticated;
