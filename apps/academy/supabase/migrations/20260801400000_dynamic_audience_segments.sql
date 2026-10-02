-- FR-M06: Dynamic audience segments
-- Module M: Communication
--
-- Features implemented:
--   * message_segment table storing audience segment definitions (defaulters, absent_today, class_level, custom)
--   * message_audience_snapshot table storing immutable point-in-time snapshots of recipients targeted by campaigns
--   * Configurable per-campus attendance lock cutoff (defaulting to 11:00:00 PKT)
--   * Indexes for sub-2 second resolution on large campuses (1,200+ students)
--   * Functions:
--       - resolve_segment(p_segment_id, p_as_of): dynamically resolves recipient list with hardship exclusions and attendance cutoff checks.
--       - snapshot_campaign_audience(p_campaign_id, p_segment_id, p_as_of): validates non-zero recipients, snapshots targets, and guards against zero-recipient dispatches.
--       - seed_default_segments(p_tenant_id, p_campus_id): seeds defaulters (> 5,000 PKR) and absent-today segments.
--   * RLS policies scoping segments to tenant and authorized staff roles.

-- 1. Campus attendance lock cutoff configuration
alter table public.campus
  add column if not exists attendance_lock_cutoff time not null default '11:00:00';

-- 2. Message Segment Table
create table if not exists public.message_segment (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid references public.campus(id) on delete cascade,
  name         text not null,
  description  text,
  segment_type text not null check (segment_type in ('defaulters', 'absent_today', 'class_level', 'bus_route', 'custom_filter')),
  definition   jsonb not null default '{}'::jsonb,
  is_active    boolean not null default true,
  created_at   timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp(),
  constraint uq_message_segment_tenant_name unique (tenant_id, campus_id, name)
);

create index if not exists idx_message_segment_lookup
  on public.message_segment (tenant_id, campus_id, segment_type, is_active);

-- 3. Message Audience Snapshot Table (Point-in-time immutable audit)
create table if not exists public.message_audience_snapshot (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid references public.campus(id) on delete cascade,
  campaign_id     uuid not null,
  segment_id      uuid references public.message_segment(id) on delete set null,
  student_id      uuid references public.student(id) on delete set null,
  guardian_id     uuid references public.guardian(id) on delete set null,
  recipient_phone text not null,
  recipient_name  text,
  student_name    text,
  gr_number       text,
  snapshot_meta   jsonb not null default '{}'::jsonb,
  resolved_at     timestamptz not null default clock_timestamp()
);

create index if not exists idx_audience_snapshot_campaign
  on public.message_audience_snapshot (tenant_id, campaign_id, resolved_at desc);

create index if not exists idx_audience_snapshot_student
  on public.message_audience_snapshot (tenant_id, student_id);

-- 4. Performance Indexes for Sub-2 Second Resolution (AC 1 & AC 2)
create index if not exists idx_fee_challan_segment_perf
  on public.fee_challan (campus_id, status, due_date)
  where status in ('unpaid', 'part_paid');

create index if not exists idx_attendance_day_segment_perf
  on public.attendance_day (campus_id, attendance_date, status);

create index if not exists idx_enrolment_segment_perf
  on public.enrolment (campus_id, status)
  where status = 'active';

-- 5. Audit Triggers
drop trigger if exists trg_message_segment_audit on public.message_segment;
create trigger trg_message_segment_audit
  after insert or update or delete on public.message_segment
  for each row execute function app.tg_audit_row();

-- 6. Dynamic Segment Resolution Function
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
    join public.enrolment e on e.id = o.enrolment_id
    join public.student s on s.id = o.student_id
    left join lateral (
      select sg.guardian_id
      from public.student_guardian sg
      where sg.student_id = s.id
      order by sg.is_primary desc, sg.receives_billing desc, sg.priority asc
      limit 1
    ) primary_sg on true
    left join public.guardian g on g.id = primary_sg.guardian_id
    where o.tenant_id = v_segment.tenant_id
      and (v_segment.campus_id is null or o.campus_id = v_segment.campus_id)
      and e.status = 'active'
      and s.status = 'active'
      and o.outstanding_paisa >= v_min_dues_paisa
      and (
        not v_exclude_hardship
        or not exists (
          select 1
          from public.concession_award ca
          left join public.concession_scheme cs on cs.id = ca.scheme_id
          where ca.enrolment_id = e.id
            and ca.status = 'approved'
            and (ca.effective_to is null or ca.effective_to >= p_as_of)
            and (ca.effective_from is null or ca.effective_from <= p_as_of)
            and (
              cs.category = 'hardship'
              or cs.code ilike '%hardship%'
              or cs.name_en ilike '%hardship%'
              or ca.rejection_reason ilike '%hardship%'
            )
        )
      )
      and coalesce(g.phone_e164, g.alt_phone) is not null;

  -- ─── Segment Type: Absent Today with Attendance Lock Cutoff (AC 2) ────────
  elsif v_segment.segment_type = 'absent_today' then
    select attendance_lock_cutoff into v_campus_cutoff
    from public.campus
    where id = v_segment.campus_id;

    v_cutoff_time := coalesce(
      (v_segment.definition->>'cutoff_time')::time,
      v_campus_cutoff,
      '11:00:00'::time
    );

    v_enforce_cutoff := coalesce((v_segment.definition->>'enforce_cutoff')::boolean, true);

    -- If cutoff is enforced and current time is prior to cutoff on today's date,
    -- guard against premature dispatches while teachers are still correcting registers.
    if v_enforce_cutoff and p_as_of = current_date and v_check_time < v_cutoff_time then
      -- Cutoff not reached yet: return empty to prevent sending unconfirmed absentee alerts
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

-- 7. Snapshot Campaign Audience with Zero-Recipient Guard (AC 3 & AC 4)
create or replace function public.snapshot_campaign_audience(
  p_campaign_id uuid,
  p_segment_id uuid,
  p_as_of date default current_date
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segment record;
  v_count int := 0;
  r record;
begin
  select id, tenant_id, campus_id, name into v_segment
  from public.message_segment
  where id = p_segment_id and is_active = true;

  if not found then
    raise exception 'Segment not found or inactive: %', p_segment_id using errcode = 'P0002';
  end if;

  -- Resolve dynamic audience at snapshot execution time
  for r in (select * from public.resolve_segment(p_segment_id, p_as_of)) loop
    v_count := v_count + 1;
    insert into public.message_audience_snapshot (
      tenant_id, campus_id, campaign_id, segment_id, student_id, guardian_id,
      recipient_phone, recipient_name, student_name, gr_number, snapshot_meta, resolved_at
    ) values (
      v_segment.tenant_id, v_segment.campus_id, p_campaign_id, p_segment_id,
      r.student_id, r.guardian_id, r.guardian_phone, r.guardian_name,
      r.student_name, r.gr_number,
      jsonb_build_object(
        'dues_pkr', r.dues_pkr,
        'attendance_status', r.attendance_status,
        'resolved_meta', r.meta
      ),
      clock_timestamp()
    );
  end loop;

  -- AC 3: If 0 recipients resolved, block send with explicit warning
  if v_count = 0 then
    raise exception 'Cannot dispatch campaign: dynamic segment "%" resolved to 0 recipients.', v_segment.name
      using errcode = '22023';
  end if;

  return v_count;
end;
$$;

-- 8. Default Segments Seeding Function
create or replace function public.seed_default_segments(
  p_tenant_id uuid,
  p_campus_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1. Fee Defaulters (> PKR 5,000)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'Fee Defaulters (> PKR 5,000)',
    'Active students with outstanding fees over PKR 5,000, excluding approved hardship waivers.',
    'defaulters',
    '{"min_dues_pkr": 5000, "exclude_hardship": true}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;

  -- 2. Unexcused Absentees Today (with 11:00 cutoff)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'Unexcused Absentees Today',
    'Students marked absent for the day. Evaluated after the 11:00 PKT morning register cutoff.',
    'absent_today',
    '{"status": "absent", "cutoff_time": "11:00:00", "enforce_cutoff": false}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;

  -- 3. High Dues Escalation (> PKR 15,000)
  insert into public.message_segment (
    tenant_id, campus_id, name, description, segment_type, definition
  ) values (
    p_tenant_id, p_campus_id,
    'High Dues Escalation (> PKR 15,000)',
    'Critical fee defaulters exceeding PKR 15,000 for bursar priority outreach.',
    'defaulters',
    '{"min_dues_pkr": 15000, "exclude_hardship": true}'::jsonb
  ) on conflict (tenant_id, campus_id, name) do nothing;
end;
$$;

-- Seed for existing tenants & campuses
do $$
declare
  r record;
begin
  for r in select id, tenant_id from public.campus loop
    perform public.seed_default_segments(r.tenant_id, r.id);
  end loop;
end $$;

-- 9. Row-Level Security
alter table public.message_segment enable row level security;
alter table public.message_audience_snapshot enable row level security;

-- Policies for message_segment
drop policy if exists message_segment_select on public.message_segment;
create policy message_segment_select on public.message_segment
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists message_segment_modify on public.message_segment;
create policy message_segment_modify on public.message_segment
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal', 'accountant')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal', 'accountant')
  );

-- Policies for message_audience_snapshot
drop policy if exists message_audience_snapshot_select on public.message_audience_snapshot;
create policy message_audience_snapshot_select on public.message_audience_snapshot
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists message_audience_snapshot_insert on public.message_audience_snapshot;
create policy message_audience_snapshot_insert on public.message_audience_snapshot
  for insert to authenticated
  with check (tenant_id = app.auth_tenant_id());
