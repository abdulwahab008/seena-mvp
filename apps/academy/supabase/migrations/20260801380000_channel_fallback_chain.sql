-- FR-M02: Per-recipient channel fallback chain
-- Module M: Communication
--
-- Features implemented:
--   * comm_channel_chain table configuring per-message-class fallback channel chains
--     (e.g. [whatsapp, sms]) with configurable timeout windows (wait_seconds).
--   * message_attempt enhancements: channel, attempt_number, escalated_from_attempt_id,
--     skip_reason (opted_out), cost tracking.
--   * message enhancements: support for 'exhausted' status and final_status tracking.
--   * comm_opt_out table capturing recipient channel-level opt-outs.
--   * message_cost_ledger tracking cost per channel attempt (ensuring dual cost rows
--     when WhatsApp fails and SMS fires).
--   * Functions:
--       - get_channel_chain(tenant_id, message_class)
--       - is_recipient_opted_out(tenant_id, phone, email, channel)
--       - next_channel_for(message_id)
--       - apply_receipt(attempt_id, status, error_code, raw_response)
--       - escalate_message(message_id, from_attempt_id, reason)
--       - escalate_timed_out_attempts(tenant_id)

-- 1. Extend message_status enum with 'exhausted' if not present
do $$
begin
  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'public.message_status'::regtype
      and enumlabel = 'exhausted'
  ) then
    alter type public.message_status add value 'exhausted';
  end if;

  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'public.attempt_status'::regtype
      and enumlabel = 'undelivered'
  ) then
    alter type public.attempt_status add value 'undelivered';
  end if;

  if not exists (
    select 1
    from pg_enum
    where enumtypid = 'public.attempt_status'::regtype
      and enumlabel = 'skipped'
  ) then
    alter type public.attempt_status add value 'skipped';
  end if;
end $$;

-- 2. Enhance public.message with final_status and message_class
alter table public.message
  add column if not exists final_status public.message_status,
  add column if not exists message_class text not null default 'default';

update public.message
set final_status = status
where final_status is null;

-- 3. Enhance public.message_attempt with channel, skip_reason, escalated_from
alter table public.message_attempt
  add column if not exists channel public.comm_channel not null default 'sms',
  add column if not exists escalated_from_attempt_id uuid references public.message_attempt(id) on delete set null,
  add column if not exists skip_reason text;

-- 4. Channel Fallback Chain Configuration
create table if not exists public.comm_channel_chain (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  message_class    text not null default 'default',
  ordered_channels public.comm_channel[] not null default array['whatsapp', 'sms']::public.comm_channel[],
  wait_seconds     jsonb not null default '{"whatsapp": 900, "sms": 600, "email": 3600, "push": 300}'::jsonb,
  is_active        boolean not null default true,
  description      text,
  created_at       timestamptz not null default clock_timestamp(),
  updated_at       timestamptz not null default clock_timestamp(),
  constraint uq_comm_channel_chain unique (tenant_id, message_class)
);

create index if not exists idx_comm_channel_chain_tenant
  on public.comm_channel_chain (tenant_id, message_class);

-- 5. Recipient Channel Opt-Out Capture & Suppression (FR-M02 & FR-M11 prerequisite)
create table if not exists public.comm_opt_out (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  recipient_phone text,
  recipient_email text,
  channel         public.comm_channel not null,
  reason          text default 'user_request',
  opted_out_at    timestamptz not null default clock_timestamp(),
  constraint uq_comm_opt_out_phone unique (tenant_id, recipient_phone, channel),
  constraint chk_comm_opt_out_target check (
    recipient_phone is not null or recipient_email is not null
  )
);

create index if not exists idx_comm_opt_out_lookup
  on public.comm_opt_out (tenant_id, recipient_phone, channel);

-- 6. Message Cost Ledger (tracks per-attempt costs honestly across fallback hops)
create table if not exists public.message_cost_ledger (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid references public.campus(id) on delete set null,
  message_id    uuid not null references public.message(id) on delete cascade,
  attempt_id    uuid references public.message_attempt(id) on delete set null,
  channel       public.comm_channel not null,
  provider_id   uuid references public.comm_provider(id) on delete set null,
  currency      text not null default 'PKR',
  cost_paisa    integer not null default 0 check (cost_paisa >= 0),
  rate_per_unit numeric(10, 4) not null default 0,
  units         integer not null default 1 check (units >= 1),
  status        text not null default 'billed', -- 'billed', 'refunded', 'pending'
  created_at    timestamptz not null default clock_timestamp()
);

create index if not exists idx_message_cost_msg
  on public.message_cost_ledger (message_id);

create index if not exists idx_message_cost_tenant_campus
  on public.message_cost_ledger (tenant_id, campus_id, created_at desc);

-- 7. Audit Triggers
drop trigger if exists trg_comm_channel_chain_audit on public.comm_channel_chain;
create trigger trg_comm_channel_chain_audit
  after insert or update or delete on public.comm_channel_chain
  for each row execute function app.tg_audit_row();

drop trigger if exists trg_comm_opt_out_audit on public.comm_opt_out;
create trigger trg_comm_opt_out_audit
  after insert or update or delete on public.comm_opt_out
  for each row execute function app.tg_audit_row();

drop trigger if exists trg_message_cost_ledger_audit on public.message_cost_ledger;
create trigger trg_message_cost_ledger_audit
  after insert or update or delete on public.message_cost_ledger
  for each row execute function app.tg_audit_row();

-- 8. Helper Functions

-- Record cost for an attempt
create or replace function public.record_message_cost(
  p_message_id uuid,
  p_attempt_id uuid,
  p_channel public.comm_channel,
  p_cost_paisa integer default null,
  p_units integer default 1
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_cost int;
  v_rate numeric(10, 4);
  v_id uuid;
begin
  select tenant_id, campus_id into v_tenant_id, v_campus_id
  from public.message
  where id = p_message_id;

  if v_tenant_id is null then
    return null;
  end if;

  -- Default cost rates: WhatsApp = 150 paisa (Rs 1.50), SMS = 100 paisa (Rs 1.00) per segment, Email/Push = 10 paisa
  if p_cost_paisa is not null then
    v_cost := p_cost_paisa;
    v_rate := p_cost_paisa::numeric / greatest(p_units, 1);
  else
    if p_channel = 'whatsapp' then
      v_cost := 150 * greatest(p_units, 1);
      v_rate := 1.50;
    elsif p_channel = 'sms' then
      v_cost := 100 * greatest(p_units, 1);
      v_rate := 1.00;
    else
      v_cost := 10 * greatest(p_units, 1);
      v_rate := 0.10;
    end if;
  end if;

  insert into public.message_cost_ledger (
    tenant_id, campus_id, message_id, attempt_id, channel, cost_paisa, rate_per_unit, units
  ) values (
    v_tenant_id, v_campus_id, p_message_id, p_attempt_id, p_channel, v_cost, v_rate, greatest(p_units, 1)
  ) returning id into v_id;

  return v_id;
end;
$$;

-- Fetch channel chain for tenant and message_class with automatic default fallback
create or replace function public.get_channel_chain(
  p_tenant_id uuid,
  p_message_class text default 'default'
)
returns table (
  ordered_channels public.comm_channel[],
  wait_seconds jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_class text := coalesce(nullif(trim(p_message_class), ''), 'default');
begin
  return query
  select c.ordered_channels, c.wait_seconds
  from public.comm_channel_chain c
  where c.tenant_id = p_tenant_id
    and c.message_class = v_class
    and c.is_active = true
  limit 1;

  if not found and v_class <> 'default' then
    return query
    select c.ordered_channels, c.wait_seconds
    from public.comm_channel_chain c
    where c.tenant_id = p_tenant_id
      and c.message_class = 'default'
      and c.is_active = true
    limit 1;
  end if;

  if not found then
    return query
    select
      array['whatsapp', 'sms']::public.comm_channel[],
      '{"whatsapp": 900, "sms": 600, "email": 3600, "push": 300}'::jsonb;
  end if;
end;
$$;

-- Check if recipient opted out of a specific channel
create or replace function public.is_recipient_opted_out(
  p_tenant_id uuid,
  p_phone text,
  p_email text,
  p_channel public.comm_channel
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_phone is not null then
    if exists (
      select 1
      from public.comm_opt_out
      where tenant_id = p_tenant_id
        and recipient_phone = p_phone
        and channel = p_channel
    ) then
      return true;
    end if;
  end if;

  if p_email is not null then
    if exists (
      select 1
      from public.comm_opt_out
      where tenant_id = p_tenant_id
        and recipient_email = p_email
        and channel = p_channel
    ) then
      return true;
    end if;
  end if;

  return false;
end;
$$;

-- Compute the next channel in the fallback chain for a message
create or replace function public.next_channel_for(
  p_message_id uuid
)
returns public.comm_channel
language plpgsql
security definer
set search_path = public
as $$
declare
  v_msg record;
  v_chain public.comm_channel[];
  v_wait jsonb;
  v_ch public.comm_channel;
  v_already_attempted public.comm_channel[];
  v_opted_out boolean;
  v_attempt_no int;
begin
  select id, tenant_id, message_class, recipient_phone, recipient_email
  into v_msg
  from public.message
  where id = p_message_id;

  if not found then
    return null;
  end if;

  select ordered_channels, wait_seconds
  into v_chain, v_wait
  from public.get_channel_chain(v_msg.tenant_id, v_msg.message_class);

  if v_chain is null or array_length(v_chain, 1) is null then
    return null;
  end if;

  -- Channels already attempted or skipped
  select array_agg(channel)
  into v_already_attempted
  from public.message_attempt
  where message_id = p_message_id;

  v_already_attempted := coalesce(v_already_attempted, array[]::public.comm_channel[]);

  -- Iterate through chain to find the next valid channel
  foreach v_ch in array v_chain
  loop
    if not (v_ch = any(v_already_attempted)) then
      -- Check if recipient opted out of this channel
      v_opted_out := public.is_recipient_opted_out(
        v_msg.tenant_id,
        v_msg.recipient_phone,
        v_msg.recipient_email,
        v_ch
      );

      if v_opted_out then
        -- Record skipped attempt for audit (AC3)
        select coalesce(max(attempt_number), 0) + 1 into v_attempt_no
        from public.message_attempt
        where message_id = p_message_id;

        insert into public.message_attempt (
          message_id, attempt_number, channel, status, skip_reason, completed_at
        ) values (
          p_message_id, v_attempt_no, v_ch, 'skipped', 'opted_out', clock_timestamp()
        );

        -- Add to attempted set and continue searching
        v_already_attempted := array_append(v_already_attempted, v_ch);
      else
        return v_ch;
      end if;
    end if;
  end loop;

  return null;
end;
$$;

-- Escalates message to next channel or marks final_status as 'exhausted'
create or replace function public.escalate_message(
  p_message_id uuid,
  p_from_attempt_id uuid default null,
  p_reason text default null
)
returns uuid -- returns the new attempt_id if created, or null if exhausted
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next_channel public.comm_channel;
  v_attempt_no int;
  v_new_attempt_id uuid;
  v_units int := 1;
begin
  v_next_channel := public.next_channel_for(p_message_id);

  if v_next_channel is not null then
    select coalesce(max(attempt_number), 0) + 1 into v_attempt_no
    from public.message_attempt
    where message_id = p_message_id;

    insert into public.message_attempt (
      message_id,
      attempt_number,
      channel,
      status,
      escalated_from_attempt_id,
      dispatched_at
    ) values (
      p_message_id,
      v_attempt_no,
      v_next_channel,
      'sending',
      p_from_attempt_id,
      clock_timestamp()
    ) returning id into v_new_attempt_id;

    -- Calculate units/segments for new channel
    select coalesce(segment_count, 1) into v_units
    from public.message
    where id = p_message_id;

    -- Record cost row for this fallback attempt (AC1: 2 cost rows exist)
    perform public.record_message_cost(
      p_message_id,
      v_new_attempt_id,
      v_next_channel,
      null,
      v_units
    );

    -- Update message queue entry to new channel and sending state
    update public.message
    set channel = v_next_channel,
        status = 'queued',
        claimed_at = null,
        claimed_by = null,
        updated_at = clock_timestamp()
    where id = p_message_id;

    return v_new_attempt_id;
  else
    -- All channels exhausted: final_status is 'exhausted' (AC3, AC4)
    update public.message
    set status = 'exhausted',
        final_status = 'exhausted',
        updated_at = clock_timestamp()
    where id = p_message_id;

    return null;
  end if;
end;
$$;

-- Apply delivery receipt webhook with fallback escalation trigger
create or replace function public.apply_receipt(
  p_attempt_id uuid,
  p_receipt_status text,
  p_error_code text default null,
  p_raw_response jsonb default null
)
returns public.attempt_status
language plpgsql
security definer
set search_path = public
as $$
declare
  v_att record;
  v_mapped_status public.attempt_status;
  v_status_text text := lower(trim(p_receipt_status));
begin
  select a.id, a.message_id, a.channel, a.status, a.attempt_number, m.status as message_status
  into v_att
  from public.message_attempt a
  join public.message m on m.id = a.message_id
  where a.id = p_attempt_id;

  if not found then
    raise exception 'message_attempt not found: %', p_attempt_id using errcode = 'P0002';
  end if;

  if v_status_text in ('delivered', 'read') then
    v_mapped_status := 'delivered';
  elsif v_status_text in ('undelivered', 'failed') then
    v_mapped_status := 'undelivered';
  elsif v_status_text in ('sent', 'dispatched') then
    v_mapped_status := 'sent';
  else
    v_mapped_status := 'unknown';
  end if;

  -- Update attempt record
  update public.message_attempt
  set status = v_mapped_status,
      error_code = coalesce(p_error_code, error_code),
      raw_response = coalesce(p_raw_response, raw_response),
      completed_at = clock_timestamp()
  where id = p_attempt_id;

  if v_mapped_status = 'delivered' then
    -- Note for AC2: A late delivered receipt arriving after fallback already fired
    -- updates this attempt and marks message delivered, but does NOT cancel or reverse
    -- the escalated SMS attempt.
    update public.message
    set status = 'delivered',
        final_status = 'delivered',
        updated_at = clock_timestamp()
    where id = v_att.message_id;
  elsif v_mapped_status = 'undelivered' then
    -- Immediately trigger fallback escalation to next channel (AC1)
    perform public.escalate_message(v_att.message_id, p_attempt_id, 'undelivered_receipt');
  end if;

  return v_mapped_status;
end;
$$;

-- Timeout scanner: scans attempts that remained in 'sent' past their channel timeout window
create or replace function public.escalate_timed_out_attempts(
  p_tenant_id uuid default null
)
returns table (
  message_id uuid,
  timed_out_attempt_id uuid,
  new_attempt_id uuid,
  escalated_to_channel public.comm_channel
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rec record;
  v_chain public.comm_channel[];
  v_wait jsonb;
  v_timeout_sec int;
  v_new_att uuid;
  v_new_ch public.comm_channel;
begin
  for v_rec in
    select a.id as attempt_id,
           a.message_id,
           a.channel,
           a.dispatched_at,
           m.tenant_id,
           m.message_class
    from public.message_attempt a
    join public.message m on m.id = a.message_id
    where a.status = 'sent'
      and m.status not in ('delivered', 'exhausted', 'cancelled')
      and (p_tenant_id is null or m.tenant_id = p_tenant_id)
      -- only consider the latest attempt for the message
      and a.attempt_number = (
        select max(sub.attempt_number)
        from public.message_attempt sub
        where sub.message_id = a.message_id
      )
  loop
    select ordered_channels, wait_seconds
    into v_chain, v_wait
    from public.get_channel_chain(v_rec.tenant_id, v_rec.message_class);

    v_timeout_sec := coalesce((v_wait->>v_rec.channel::text)::int, 900);

    if clock_timestamp() - v_rec.dispatched_at >= make_interval(secs => v_timeout_sec) then
      -- Mark this attempt as timed out
      update public.message_attempt
      set status = 'timeout',
          error_code = 'DELIVERY_RECEIPT_TIMEOUT',
          error_message = format('No delivery receipt received within %s seconds', v_timeout_sec),
          completed_at = clock_timestamp()
      where id = v_rec.attempt_id;

      -- Fire fallback escalation
      v_new_att := public.escalate_message(v_rec.message_id, v_rec.attempt_id, 'timeout_window_elapsed');

      if v_new_att is not null then
        select channel into v_new_ch from public.message_attempt where id = v_new_att;
      else
        v_new_ch := null;
      end if;

      message_id := v_rec.message_id;
      timed_out_attempt_id := v_rec.attempt_id;
      new_attempt_id := v_new_att;
      escalated_to_channel := v_new_ch;
      return next;
    end if;
  end loop;
end;
$$;

-- 9. Row-Level Security
alter table public.comm_channel_chain enable row level security;
alter table public.comm_opt_out enable row level security;
alter table public.message_cost_ledger enable row level security;

-- Policies for comm_channel_chain
drop policy if exists comm_channel_chain_select on public.comm_channel_chain;
create policy comm_channel_chain_select on public.comm_channel_chain
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists comm_channel_chain_modify on public.comm_channel_chain;
create policy comm_channel_chain_modify on public.comm_channel_chain
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  );

-- Policies for comm_opt_out
drop policy if exists comm_opt_out_select on public.comm_opt_out;
create policy comm_opt_out_select on public.comm_opt_out
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists comm_opt_out_modify on public.comm_opt_out;
create policy comm_opt_out_modify on public.comm_opt_out
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal')
  );

-- Policies for message_cost_ledger
drop policy if exists message_cost_ledger_select on public.message_cost_ledger;
create policy message_cost_ledger_select on public.message_cost_ledger
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

drop policy if exists message_cost_ledger_modify on public.message_cost_ledger;
create policy message_cost_ledger_modify on public.message_cost_ledger
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin')
  );

-- 10. Seed Default Fallback Chains for Active Tenants
insert into public.comm_channel_chain (
  tenant_id, message_class, ordered_channels, wait_seconds, description
)
select
  id as tenant_id,
  'default' as message_class,
  array['whatsapp', 'sms']::public.comm_channel[],
  '{"whatsapp": 900, "sms": 600, "email": 3600, "push": 300}'::jsonb,
  'Default delivery fallback: WhatsApp with 15-min timeout, falling back to SMS'
from public.tenant
on conflict (tenant_id, message_class) do nothing;

insert into public.comm_channel_chain (
  tenant_id, message_class, ordered_channels, wait_seconds, description
)
select
  id as tenant_id,
  'emergency' as message_class,
  array['sms', 'whatsapp']::public.comm_channel[],
  '{"sms": 180, "whatsapp": 300}'::jsonb,
  'Emergency alert: immediate SMS with rapid 3-min timeout, followed by WhatsApp'
from public.tenant
on conflict (tenant_id, message_class) do nothing;
