-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: 20260801430000_delivery_receipt_ingestion.sql
-- Module M: Communication — FR-M09: Delivery receipt ingestion
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. Extend enums for attempt and message statuses if missing
alter type public.attempt_status add value if not exists 'submitted';
alter type public.attempt_status add value if not exists 'expired';

alter type public.message_status add value if not exists 'submitted';
alter type public.message_status add value if not exists 'expired';
alter type public.message_status add value if not exists 'sent';

-- 2. Delivery receipts audit table
create table if not exists public.message_receipt (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  message_attempt_id uuid references public.message_attempt(id) on delete set null,
  provider text not null,
  provider_ref text not null,
  status public.attempt_status not null,
  raw jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default clock_timestamp()
);

create index if not exists idx_message_receipt_tenant on public.message_receipt(tenant_id, received_at desc);
create index if not exists idx_message_receipt_attempt on public.message_receipt(message_attempt_id);
create index if not exists idx_message_receipt_provider_ref on public.message_receipt(provider_ref);

-- 3. Dead letter receipts table (for mismatched provider_ref, retained 30 days)
create table if not exists public.dead_letter_receipt (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  provider text not null,
  provider_ref text not null,
  payload jsonb not null default '{}'::jsonb,
  reason text not null default 'attempt_not_found',
  received_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default (clock_timestamp() + interval '30 days')
);

create index if not exists idx_dead_letter_receipt_tenant on public.dead_letter_receipt(tenant_id, received_at desc);
create index if not exists idx_dead_letter_receipt_expires on public.dead_letter_receipt(expires_at);

-- 4. Monotonic state rank helper function
create or replace function public.comm_status_rank(p_status public.attempt_status)
returns int
language sql
immutable
as $$
  select case p_status
    when 'sending' then 1
    when 'submitted' then 2
    when 'sent' then 3
    when 'delivered' then 4
    when 'failed' then 4
    when 'undelivered' then 4
    when 'expired' then 4
    when 'timeout' then 4
    when 'skipped' then 4
    when 'unknown' then 3
    else 1
  end;
$$;

-- 5. Apply delivery receipt function with monotonic state machine
create or replace function public.apply_receipt(
  p_provider text,
  p_payload jsonb,
  p_tenant_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_provider_ref text;
  v_raw_status text;
  v_mapped_status public.attempt_status;
  v_attempt record;
  v_current_rank int;
  v_new_rank int;
  v_tenant_id uuid := p_tenant_id;
  v_receipt_id uuid;
begin
  -- Extract provider reference and status from common payload shapes
  v_provider_ref := coalesce(
    p_payload->>'provider_ref',
    p_payload->>'message_id',
    p_payload->>'id',
    p_payload->>'sms_id',
    p_payload->>'sid'
  );

  if v_provider_ref is null or trim(v_provider_ref) = '' then
    raise exception 'MISSING_PROVIDER_REF';
  end if;

  v_raw_status := lower(coalesce(
    p_payload->>'status',
    p_payload->>'event',
    p_payload->>'delivery_status',
    'unknown'
  ));

  -- Normalize raw provider status to attempt_status
  case v_raw_status
    when 'delivered', 'dlr_delivered', 'read', 'received' then
      v_mapped_status := 'delivered'::public.attempt_status;
    when 'failed', 'dlr_failed', 'undelivered', 'bounced', 'rejected' then
      v_mapped_status := 'failed'::public.attempt_status;
    when 'expired', 'dlr_expired' then
      v_mapped_status := 'expired'::public.attempt_status;
    when 'sent', 'transferred' then
      v_mapped_status := 'sent'::public.attempt_status;
    when 'submitted', 'buffered', 'queued' then
      v_mapped_status := 'submitted'::public.attempt_status;
    else
      v_mapped_status := 'unknown'::public.attempt_status;
  end case;

  -- Locate matching attempt
  select ma.id, ma.message_id, ma.status, m.tenant_id
  into v_attempt
  from public.message_attempt ma
  join public.message m on m.id = ma.message_id
  where ma.provider_ref = v_provider_ref
  limit 1;

  -- AC 3: If no attempt matches provider_ref, write to dead_letter_receipt
  if v_attempt.id is null then
    if v_tenant_id is null then
      -- Fallback to first active tenant if tenant context was not provided by webhook
      select id into v_tenant_id from public.tenant where status = 'active' order by created_at asc limit 1;
    end if;

    if v_tenant_id is null then
      select id into v_tenant_id from public.tenant limit 1;
    end if;

    insert into public.dead_letter_receipt (
      tenant_id,
      provider,
      provider_ref,
      payload,
      reason,
      received_at,
      expires_at
    ) values (
      v_tenant_id,
      p_provider,
      v_provider_ref,
      p_payload,
      'attempt_not_found',
      clock_timestamp(),
      clock_timestamp() + interval '30 days'
    );

    return jsonb_build_object(
      'success', true,
      'action', 'dead_letter',
      'provider_ref', v_provider_ref,
      'reason', 'attempt_not_found'
    );
  end if;

  v_tenant_id := v_attempt.tenant_id;

  -- Record receipt audit row regardless of whether state advances
  insert into public.message_receipt (
    tenant_id,
    message_attempt_id,
    provider,
    provider_ref,
    status,
    raw,
    received_at
  ) values (
    v_tenant_id,
    v_attempt.id,
    p_provider,
    v_provider_ref,
    v_mapped_status,
    p_payload,
    clock_timestamp()
  ) returning id into v_receipt_id;

  -- AC 1: Monotonic state machine check
  -- Check ranks: queued/sending (1) -> submitted (2) -> sent (3) -> delivered/failed/expired (4)
  v_current_rank := public.comm_status_rank(v_attempt.status);
  v_new_rank := public.comm_status_rank(v_mapped_status);

  -- Only advance forward. If current is terminal (rank 4), or new rank <= current rank, state is unchanged
  if v_current_rank < 4 and v_new_rank > v_current_rank then
    update public.message_attempt
    set
      status = v_mapped_status,
      completed_at = case when v_new_rank = 4 then clock_timestamp() else completed_at end,
      raw_response = coalesce(raw_response, '{}'::jsonb) || jsonb_build_object('latest_dlr', p_payload)
    where id = v_attempt.id;

    -- Update parent message status
    if v_mapped_status = 'delivered' then
      update public.message
      set status = 'delivered'::public.message_status,
          final_status = 'delivered'::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id;
    elsif v_mapped_status in ('failed', 'expired') then
      update public.message
      set status = v_mapped_status::text::public.message_status,
          final_status = v_mapped_status::text::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id;
    elsif v_mapped_status = 'sent' then
      update public.message
      set status = 'sent'::public.message_status,
          updated_at = clock_timestamp()
      where id = v_attempt.message_id and status in ('queued', 'claimed', 'sending');
    end if;

    return jsonb_build_object(
      'success', true,
      'action', 'advanced',
      'previous_status', v_attempt.status,
      'new_status', v_mapped_status,
      'receipt_id', v_receipt_id
    );
  else
    -- State rejected backwards or already at terminal status; state unchanged, receipt audited
    return jsonb_build_object(
      'success', true,
      'action', 'preserved',
      'status', v_attempt.status,
      'ignored_status', v_mapped_status,
      'receipt_id', v_receipt_id
    );
  end if;
end;
$$;

-- 6. AC 4: Stale attempt sweeper (expires attempts in 'sent' older than cutoff, default 24h)
create or replace function public.expire_stale_attempts(
  p_tenant_id uuid default null,
  p_cutoff_interval interval default interval '24 hours'
)
returns table (
  expired_count int,
  expired_attempt_ids uuid[]
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_ids uuid[];
  v_count int := 0;
begin
  select coalesce(array_agg(ma.id), '{}')
  into v_ids
  from public.message_attempt ma
  join public.message m on m.id = ma.message_id
  where (p_tenant_id is null or m.tenant_id = p_tenant_id)
    and ma.status in ('sent'::public.attempt_status, 'sending'::public.attempt_status, 'submitted'::public.attempt_status)
    and ma.dispatched_at <= (clock_timestamp() - p_cutoff_interval);

  v_count := array_length(v_ids, 1);
  if v_count is null then
    v_count := 0;
  end if;

  if v_count > 0 then
    -- Mark attempts expired
    update public.message_attempt
    set
      status = 'expired'::public.attempt_status,
      completed_at = clock_timestamp(),
      error_message = 'EXPIRED_NO_DLR_AFTER_24H'
    where id = any(v_ids);

    -- Also update parent messages whose active attempts expired
    update public.message m
    set
      status = 'expired'::public.message_status,
      final_status = 'expired'::public.message_status,
      updated_at = clock_timestamp()
    where m.id in (
      select message_id from public.message_attempt where id = any(v_ids)
    ) and m.status in ('queued'::public.message_status, 'claimed'::public.message_status, 'sending'::public.message_status, 'sent'::public.message_status);
  end if;

  return query select v_count, v_ids;
end;
$$;

-- 7. View for campaign and delivery statistics
create or replace view public.v_campaign_delivery_stats as
select
  m.tenant_id,
  m.batch_id as campaign_id,
  count(distinct m.id) as total_messages,
  count(distinct ma.id) as total_attempts,
  count(distinct case when ma.status = 'delivered' then ma.id end) as delivered_count,
  count(distinct case when ma.status in ('failed', 'undelivered', 'timeout') then ma.id end) as failed_count,
  count(distinct case when ma.status = 'expired' then ma.id end) as expired_count,
  count(distinct case when ma.status in ('sent', 'submitted', 'sending') then ma.id end) as pending_sent_count,
  round(
    coalesce(
      count(distinct case when ma.status = 'delivered' then ma.id end)::numeric /
      nullif(count(distinct ma.id), 0) * 100,
      0
    ),
    1
  ) as delivery_rate_pct
from public.message m
left join public.message_attempt ma on ma.message_id = m.id
group by m.tenant_id, m.batch_id;

-- 8. Row Level Security policies
alter table public.message_receipt enable row level security;
alter table public.dead_letter_receipt enable row level security;

create policy "message_receipt_tenant_read"
  on public.message_receipt for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'admin', 'coordinator'))
  );

create policy "dead_letter_receipt_tenant_read"
  on public.dead_letter_receipt for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'admin'))
  );

-- Grants
grant select on public.message_receipt to authenticated;
grant select on public.dead_letter_receipt to authenticated;
grant select on public.v_campaign_delivery_stats to authenticated;
grant execute on function public.apply_receipt(text, jsonb, uuid) to authenticated, anon;
grant execute on function public.expire_stale_attempts(uuid, interval) to authenticated;
