-- ═══════════════════════════════════════════════════════════════════════
-- Migration: 20260801410000_scheduled_sends_with_quiet_hours.sql
-- Module M: Communication
-- Requirement: FR-M07: Scheduled sends with quiet hours (No. 209, P1)
-- ═══════════════════════════════════════════════════════════════════════
-- Scope:
-- 1. Tables:
--    - tenant_comm_policy: Quiet hours window (quiet_start, quiet_end) & emergency bypass role.
--    - comm_quiet_hours_override: Date-range overrides (e.g. Ramadan quiet window) for special seasons.
--    - message_campaign: Campaigns with scheduled_at, timezone, status, deferred_until, emergency flags.
--    - quiet_hours_bypass_log: Audit trail of emergency bypasses naming human approver & reason.
-- 2. Functions:
--    - is_quiet_now(tenant_id, at): Checks whether given timestamp falls in quiet hours (override or default).
--    - get_next_quiet_window_end(tenant_id, at): Computes next 08:00:00 PKT resumption timestamp.
--    - schedule_campaign(...): Validates future timestamp (AC 3), evaluates quiet hours (AC 1), logs emergency bypass (AC 2).
--    - evaluate_scheduled_campaigns(...): Background dispatcher evaluation engine.
--    - seed_default_comm_policy(tenant_id): Seeds default quiet hours (21:00 to 08:00 PKT).
-- 3. RLS & Permissions.
-- ═══════════════════════════════════════════════════════════════════════

-- ─── 1. Tenant Communication Policy ─────────────────────────────────────
create table if not exists public.tenant_comm_policy (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null unique references public.tenant(id) on delete cascade,
  quiet_start           time not null default '21:00:00',
  quiet_end             time not null default '08:00:00',
  timezone              text not null default 'Asia/Karachi',
  emergency_bypass_role text not null default 'principal',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

-- ─── 2. Seasonal / Ramadan Quiet Hours Override ─────────────────────────
create table if not exists public.comm_quiet_hours_override (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  name        text not null,
  date_range  daterange not null,
  quiet_start time not null,
  quiet_end   time not null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists idx_comm_quiet_override_range
  on public.comm_quiet_hours_override (tenant_id, date_range);

-- ─── 3. Message Campaign Table ──────────────────────────────────────────
create table if not exists public.message_campaign (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  campus_id               uuid references public.campus(id) on delete cascade,
  title                   text not null,
  segment_id              uuid references public.message_segment(id) on delete set null,
  template_id             uuid references public.message_template(id) on delete set null,
  channel                 text not null default 'sms',
  body                    text not null,
  scheduled_at            timestamptz not null,
  timezone                text not null default 'Asia/Karachi',
  status                  text not null default 'scheduled',
  deferred_until          timestamptz,
  is_emergency            boolean not null default false,
  emergency_bypass_reason text,
  emergency_approved_by   uuid references public.app_user(user_id) on delete set null,
  created_by              uuid references public.app_user(user_id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint ck_campaign_status check (
    status in ('draft', 'scheduled', 'deferred_quiet_hours', 'dispatching', 'dispatched', 'cancelled')
  )
);

create index if not exists idx_message_campaign_dispatch
  on public.message_campaign (tenant_id, status, scheduled_at);

-- ─── 4. Quiet Hours Emergency Bypass Log ────────────────────────────────
create table if not exists public.quiet_hours_bypass_log (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campaign_id       uuid not null references public.message_campaign(id) on delete cascade,
  approver_user_id  uuid not null references public.app_user(user_id) on delete cascade,
  approver_role     text not null,
  bypass_reason     text not null,
  scheduled_at      timestamptz not null,
  dispatched_at     timestamptz not null default now(),
  metadata          jsonb not null default '{}'::jsonb
);

create index if not exists idx_quiet_hours_bypass_tenant
  on public.quiet_hours_bypass_log (tenant_id, dispatched_at);

-- ─── 5. Core Functions ──────────────────────────────────────────────────

-- 5a. Helper to seed default communication policy
create or replace function public.seed_default_comm_policy(p_tenant_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.tenant_comm_policy (
    tenant_id, quiet_start, quiet_end, timezone, emergency_bypass_role
  ) values (
    p_tenant_id, '21:00:00', '08:00:00', 'Asia/Karachi', 'principal'
  )
  on conflict (tenant_id) do update
    set updated_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

-- 5b. Function: is_quiet_now(tenant_id, at)
-- Checks whether a given timestamp (evaluated in tenant timezone) falls within quiet hours.
-- Takes into account seasonal date-range overrides (e.g. Ramadan) before falling back to default policy.
create or replace function public.is_quiet_now(
  p_tenant_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz           text := 'Asia/Karachi';
  v_local_ts     timestamp;
  v_local_date   date;
  v_local_time   time;
  v_quiet_start  time;
  v_quiet_end    time;
  v_override_rec record;
begin
  -- Resolve tenant timezone & default quiet hours
  select timezone, quiet_start, quiet_end
  into v_tz, v_quiet_start, v_quiet_end
  from public.tenant_comm_policy
  where tenant_id = p_tenant_id;

  if v_tz is null then
    v_tz := 'Asia/Karachi';
    v_quiet_start := '21:00:00'::time;
    v_quiet_end := '08:00:00'::time;
  end if;

  -- Convert UTC timestamptz to local timestamp
  v_local_ts := timezone(v_tz, p_at);
  v_local_date := v_local_ts::date;
  v_local_time := v_local_ts::time;

  -- Check for active seasonal override (AC 4)
  select quiet_start, quiet_end
  into v_override_rec
  from public.comm_quiet_hours_override
  where tenant_id = p_tenant_id
    and date_range @> v_local_date
  order by created_at desc
  limit 1;

  if v_override_rec.quiet_start is not null then
    v_quiet_start := v_override_rec.quiet_start;
    v_quiet_end := v_override_rec.quiet_end;
  end if;

  -- Quiet window spans overnight (e.g., 21:00 to 08:00 or 22:00 to 08:00)
  if v_quiet_start > v_quiet_end then
    return (v_local_time >= v_quiet_start or v_local_time < v_quiet_end);
  else
    -- Intra-day quiet window (e.g., 13:00 to 15:00)
    return (v_local_time >= v_quiet_start and v_local_time < v_quiet_end);
  end if;
end;
$$;

-- 5c. Helper: get_next_quiet_window_end(tenant_id, at)
-- Returns the exact timestamptz (in UTC) when the next morning quiet window opens (e.g. 08:00 PKT).
create or replace function public.get_next_quiet_window_end(
  p_tenant_id uuid,
  p_at timestamptz default clock_timestamp()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz          text := 'Asia/Karachi';
  v_local_ts    timestamp;
  v_local_date  date;
  v_local_time  time;
  v_quiet_start time := '21:00:00'::time;
  v_quiet_end   time := '08:00:00'::time;
  v_resume_date date;
  v_resume_ts   timestamp;
  v_override    record;
begin
  select timezone, quiet_start, quiet_end
  into v_tz, v_quiet_start, v_quiet_end
  from public.tenant_comm_policy
  where tenant_id = p_tenant_id;

  if v_tz is null then
    v_tz := 'Asia/Karachi';
    v_quiet_start := '21:00:00'::time;
    v_quiet_end := '08:00:00'::time;
  end if;

  v_local_ts := timezone(v_tz, p_at);
  v_local_date := v_local_ts::date;
  v_local_time := v_local_ts::time;

  -- Check seasonal override
  select quiet_start, quiet_end
  into v_override
  from public.comm_quiet_hours_override
  where tenant_id = p_tenant_id
    and date_range @> v_local_date
  order by created_at desc
  limit 1;

  if v_override.quiet_start is not null then
    v_quiet_start := v_override.quiet_start;
    v_quiet_end := v_override.quiet_end;
  end if;

  -- If local time is late at night (>= quiet_start), resume is tomorrow at quiet_end
  if v_local_time >= v_quiet_start then
    v_resume_date := v_local_date + interval '1 day';
  else
    -- If local time is early morning (< quiet_end), resume is today at quiet_end
    v_resume_date := v_local_date;
  end if;

  v_resume_ts := (v_resume_date || ' ' || v_quiet_end)::timestamp;
  return timezone(v_tz, v_resume_ts);
end;
$$;

-- 5d. Function: schedule_campaign(...)
-- Implements validation for past timestamps (AC 3), emergency bypass with audit logging (AC 2),
-- and deferred quiet hours scheduling (AC 1).
create or replace function public.schedule_campaign(
  p_title                   text,
  p_segment_id              uuid,
  p_template_id             uuid,
  p_channel                 text,
  p_body                    text,
  p_scheduled_at            timestamptz,
  p_timezone                text default 'Asia/Karachi',
  p_is_emergency            boolean default false,
  p_emergency_bypass_reason text default null,
  p_campus_id               uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid;
  v_user_id       uuid;
  v_role          text;
  v_campaign_id   uuid;
  v_status        text := 'scheduled';
  v_deferred_until timestamptz := null;
  v_is_quiet      boolean;
begin
  v_tenant_id := app.auth_tenant_id();
  v_user_id := coalesce((select auth.uid()), (app.jwt() ->> 'sub')::uuid);
  v_role := coalesce(app.auth_role(), 'principal');

  if v_tenant_id is null then
    raise exception 'FORBIDDEN: Tenant context required' using errcode = '42501';
  end if;

  -- ─── AC 3: Validation Error on Past Timestamp ──────────────────────────
  -- When a campaign is scheduled with a timestamp in the past, it must be rejected
  -- with a validation error rather than firing immediately.
  if p_scheduled_at < (clock_timestamp() - interval '1 minute') and not p_is_emergency then
    raise exception 'SCHEDULED_TIME_IN_PAST: Scheduled time (%) cannot be in the past.',
      to_char(p_scheduled_at, 'YYYY-MM-DD HH24:MI:SS TZ')
      using errcode = '22023';
  end if;

  -- Check if scheduled time falls in quiet hours
  v_is_quiet := public.is_quiet_now(v_tenant_id, p_scheduled_at);

  -- ─── AC 2: Emergency School-Closure / Bypass ───────────────────────────
  if p_is_emergency then
    if v_role not in ('super_admin', 'owner', 'principal') then
      raise exception 'FORBIDDEN: Emergency bypass requires Principal or Owner authorization'
        using errcode = '42501';
    end if;

    if p_emergency_bypass_reason is null or length(trim(p_emergency_bypass_reason)) = 0 then
      raise exception 'EMERGENCY_REASON_REQUIRED: A specific reason must be documented for quiet hours bypass'
        using errcode = '22023';
    end if;

    v_status := 'dispatching';
  elsif v_is_quiet then
    -- ─── AC 1: Deferred to Next Morning 08:00 PKT ───────────────────────
    v_status := 'deferred_quiet_hours';
    v_deferred_until := public.get_next_quiet_window_end(v_tenant_id, p_scheduled_at);
  else
    v_status := 'scheduled';
  end if;

  -- Insert Campaign Record
  insert into public.message_campaign (
    tenant_id, campus_id, title, segment_id, template_id, channel, body,
    scheduled_at, timezone, status, deferred_until, is_emergency,
    emergency_bypass_reason, emergency_approved_by, created_by
  ) values (
    v_tenant_id, p_campus_id, p_title, p_segment_id, p_template_id, p_channel, p_body,
    p_scheduled_at, coalesce(p_timezone, 'Asia/Karachi'), v_status, v_deferred_until,
    p_is_emergency, p_emergency_bypass_reason,
    case when p_is_emergency then v_user_id end, v_user_id
  ) returning id into v_campaign_id;

  -- Write to Quiet Hours Bypass Log if emergency bypass occurred (AC 2)
  if p_is_emergency then
    insert into public.quiet_hours_bypass_log (
      tenant_id, campaign_id, approver_user_id, approver_role,
      bypass_reason, scheduled_at, dispatched_at, metadata
    ) values (
      v_tenant_id, v_campaign_id, coalesce(v_user_id, '00000000-0000-0000-0000-000000000000'::uuid),
      v_role, p_emergency_bypass_reason, p_scheduled_at, clock_timestamp(),
      jsonb_build_object(
        'channel', p_channel,
        'title', p_title,
        'bypassed_quiet_window', v_is_quiet
      )
    );
  end if;

  return v_campaign_id;
end;
$$;

-- 5e. Function: evaluate_scheduled_campaigns(tenant_id, as_of)
-- Evaluates scheduled campaigns. If evaluated at quiet hours, transitions to 'deferred_quiet_hours'.
-- If deferred and now reached resumption (e.g. 08:00 morning), dispatches.
create or replace function public.evaluate_scheduled_campaigns(
  p_tenant_id uuid default null,
  p_as_of timestamptz default clock_timestamp()
)
returns table (
  campaign_id        uuid,
  title              text,
  previous_status    text,
  new_status         text,
  deferred_until_out timestamptz,
  notes              text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
  v_is_quiet boolean;
  v_next_end timestamptz;
begin
  for v_rec in
    select c.*
    from public.message_campaign c
    where (p_tenant_id is null or c.tenant_id = p_tenant_id)
      and c.status in ('scheduled', 'deferred_quiet_hours')
      and (
        (c.status = 'scheduled' and c.scheduled_at <= p_as_of)
        or (c.status = 'deferred_quiet_hours' and coalesce(c.deferred_until, c.scheduled_at) <= p_as_of)
      )
    order by c.scheduled_at asc
  loop
    v_is_quiet := public.is_quiet_now(v_rec.tenant_id, p_as_of);

    if v_rec.is_emergency then
      -- Emergency always dispatches immediately
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := v_rec.status;
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Emergency campaign dispatched immediately via authorized bypass';
      return next;

    elsif v_rec.status = 'scheduled' and v_is_quiet then
      -- Scheduled for 22:30 PKT -> Deferred to 08:00 next morning (AC 1)
      v_next_end := public.get_next_quiet_window_end(v_rec.tenant_id, p_as_of);

      update public.message_campaign
      set status = 'deferred_quiet_hours',
          deferred_until = v_next_end,
          updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'scheduled';
      new_status := 'deferred_quiet_hours';
      deferred_until_out := v_next_end;
      notes := 'Quiet hours active: deferred send until 08:00 next morning';
      return next;

    elsif v_rec.status = 'deferred_quiet_hours' and not v_is_quiet then
      -- Resumption reached at 08:00: dispatching
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'deferred_quiet_hours';
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Quiet hours window ended; dispatching deferred campaign';
      return next;

    elsif v_rec.status = 'scheduled' and not v_is_quiet then
      -- Normal dispatch outside quiet hours
      update public.message_campaign
      set status = 'dispatching', updated_at = clock_timestamp()
      where id = v_rec.id;

      campaign_id := v_rec.id;
      title := v_rec.title;
      previous_status := 'scheduled';
      new_status := 'dispatching';
      deferred_until_out := null;
      notes := 'Normal daytime schedule reached; dispatching campaign';
      return next;
    end if;
  end loop;
end;
$$;

-- ─── 6. Security & RLS Policies ─────────────────────────────────────────
alter table public.tenant_comm_policy enable row level security;
alter table public.comm_quiet_hours_override enable row level security;
alter table public.message_campaign enable row level security;
alter table public.quiet_hours_bypass_log enable row level security;

-- Tenant isolation RLS
create policy tenant_comm_policy_tenant_isolation on public.tenant_comm_policy
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

create policy comm_quiet_hours_override_isolation on public.comm_quiet_hours_override
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

create policy message_campaign_isolation on public.message_campaign
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

create policy quiet_hours_bypass_log_isolation on public.quiet_hours_bypass_log
  for all using (tenant_id = app.auth_tenant_id())
  with check (tenant_id = app.auth_tenant_id());

-- Grant execution to authenticated users
grant execute on function public.is_quiet_now(uuid, timestamptz) to authenticated;
grant execute on function public.get_next_quiet_window_end(uuid, timestamptz) to authenticated;
grant execute on function public.schedule_campaign(text, uuid, uuid, text, text, timestamptz, text, boolean, text, uuid) to authenticated;
grant execute on function public.evaluate_scheduled_campaigns(uuid, timestamptz) to authenticated;
grant execute on function public.seed_default_comm_policy(uuid) to authenticated;
