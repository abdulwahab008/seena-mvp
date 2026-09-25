-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: 20260801440000_comm_cost_ledger_and_wallet.sql
-- Module M: Communication — FR-M10: Message cost ledger and credit guard
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. Effective-dated Provider Rate Card
create table if not exists public.provider_rate_card (
  id uuid primary key default gen_random_uuid(),
  channel public.comm_channel not null,
  encoding text not null default 'gsm7', -- 'gsm7', 'ucs2'
  network text not null default 'all',    -- 'jazz', 'telenor', 'zong', 'ufone', 'all'
  rate_paisa integer not null check (rate_paisa > 0),
  effective_from date not null default current_date,
  effective_to date,
  created_at timestamptz not null default clock_timestamp(),
  constraint chk_rate_card_dates check (effective_to is null or effective_to >= effective_from)
);

create index if not exists idx_rate_card_lookup 
  on public.provider_rate_card(channel, encoding, network, effective_from, effective_to);

-- Seed baseline Pakistani telco rate card entries (effective immediately)
insert into public.provider_rate_card (channel, encoding, network, rate_paisa, effective_from)
values
  ('sms', 'ucs2', 'all', 120, '2026-01-01'), -- 120 paisa = PKR 1.20 / Urdu segment
  ('sms', 'gsm7', 'all', 80,  '2026-01-01'), -- 80 paisa = PKR 0.80 / English segment
  ('whatsapp', 'gsm7', 'all', 250, '2026-01-01'), -- 250 paisa = PKR 2.50 / conversation
  ('whatsapp', 'ucs2', 'all', 250, '2026-01-01')
on conflict do nothing;

-- 2. Prepaid Messaging Wallet
create table if not exists public.tenant_comm_wallet (
  tenant_id uuid primary key references public.tenant(id) on delete cascade,
  balance_paisa bigint not null default 0 check (balance_paisa >= 0),
  currency text not null default 'PKR',
  updated_at timestamptz not null default clock_timestamp()
);

-- Wallet transaction ledger
create table if not exists public.tenant_comm_wallet_txn (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  txn_type text not null check (txn_type in ('top_up', 'debit', 'refund', 'reserve', 'release')),
  amount_paisa bigint not null,
  balance_after_paisa bigint not null check (balance_after_paisa >= 0),
  reference text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists idx_wallet_txn_tenant on public.tenant_comm_wallet_txn(tenant_id, created_at desc);

-- 3. Enhance message_cost_ledger with conversation_id and rate_card_id
alter table public.message_cost_ledger 
  add column if not exists conversation_id text,
  add column if not exists rate_card_id uuid references public.provider_rate_card(id) on delete set null;

-- AC 2: Unique constraint to ensure exactly ONE conversation-level cost row per 24h window
create unique index if not exists uq_message_cost_wa_conversation 
  on public.message_cost_ledger(tenant_id, conversation_id) 
  where conversation_id is not null;

-- Alias view for comm_cost_ledger matching FR-M10 naming
create or replace view public.comm_cost_ledger as
select
  id,
  tenant_id,
  campus_id,
  message_id,
  attempt_id,
  channel,
  conversation_id,
  units,
  cost_paisa,
  rate_per_unit,
  rate_card_id,
  status,
  created_at
from public.message_cost_ledger;

-- 4. Debit Comm Wallet Function (AC 4: Concurrency control using SELECT ... FOR UPDATE)
create or replace function public.debit_comm_wallet(
  p_tenant_id uuid,
  p_paisa bigint,
  p_reference text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_current_balance bigint;
  v_new_balance bigint;
begin
  if p_paisa <= 0 then
    raise exception 'DEBIT_AMOUNT_MUST_BE_POSITIVE';
  end if;

  -- Row lock on tenant wallet for strict concurrency serialization
  select balance_paisa
  into v_current_balance
  from public.tenant_comm_wallet
  where tenant_id = p_tenant_id
  for update;

  if v_current_balance is null then
    raise exception 'WALLET_NOT_INITIALIZED';
  end if;

  if v_current_balance < p_paisa then
    -- Format PKR shortfall
    raise exception 'INSUFFICIENT_COMM_BALANCE: Shortfall of PKR % (Required: PKR %, Available: PKR %)',
      to_char((p_paisa - v_current_balance)::numeric / 100, 'FM999,990.00'),
      to_char(p_paisa::numeric / 100, 'FM999,990.00'),
      to_char(v_current_balance::numeric / 100, 'FM999,990.00')
      using errcode = '23514';
  end if;

  v_new_balance := v_current_balance - p_paisa;

  update public.tenant_comm_wallet
  set balance_paisa = v_new_balance,
      updated_at = clock_timestamp()
  where tenant_id = p_tenant_id;

  insert into public.tenant_comm_wallet_txn (
    tenant_id, txn_type, amount_paisa, balance_after_paisa, reference, metadata
  ) values (
    p_tenant_id, 'debit', p_paisa, v_new_balance, p_reference, p_metadata
  );

  return v_new_balance;
end;
$$;

-- 5. Top-up Comm Wallet Function
create or replace function public.top_up_comm_wallet(
  p_tenant_id uuid,
  p_paisa bigint,
  p_reference text default 'Prepaid credit top-up',
  p_metadata jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_new_balance bigint;
begin
  if p_paisa <= 0 then
    raise exception 'TOPUP_AMOUNT_MUST_BE_POSITIVE';
  end if;

  insert into public.tenant_comm_wallet (tenant_id, balance_paisa, updated_at)
  values (p_tenant_id, p_paisa, clock_timestamp())
  on conflict (tenant_id) do update
  set balance_paisa = public.tenant_comm_wallet.balance_paisa + excluded.balance_paisa,
      updated_at = clock_timestamp()
  returning balance_paisa into v_new_balance;

  insert into public.tenant_comm_wallet_txn (
    tenant_id, txn_type, amount_paisa, balance_after_paisa, reference, metadata
  ) values (
    p_tenant_id, 'top_up', p_paisa, v_new_balance, p_reference, p_metadata
  );

  return v_new_balance;
end;
$$;

-- 6. Estimate Campaign Cost Function
create or replace function public.estimate_campaign_cost(p_batch_id uuid)
returns bigint
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_total_paisa bigint := 0;
  v_rec record;
  v_rate int;
  v_encoding text;
begin
  for v_rec in
    select
      m.channel,
      coalesce(m.segment_count, 1) as segments,
      case when m.body ~ '[\u0600-\u06FF]' then 'ucs2' else 'gsm7' end as encoding
    from public.message m
    where m.batch_id = p_batch_id
  loop
    -- Find effective rate card
    select rate_paisa into v_rate
    from public.provider_rate_card
    where channel = v_rec.channel
      and encoding = v_rec.encoding
      and effective_from <= current_date
      and (effective_to is null or effective_to >= current_date)
    order by effective_from desc
    limit 1;

    if v_rate is null then
      v_rate := case when v_rec.encoding = 'ucs2' then 120 else 80 end;
    end if;

    if v_rec.channel = 'whatsapp' then
      v_total_paisa := v_total_paisa + v_rate; -- per conversation
    else
      v_total_paisa := v_total_paisa + (v_rate * v_rec.segments);
    end if;
  end loop;

  return coalesce(v_total_paisa, 0);
end;
$$;

-- 7. Guard Campaign Dispatch Function (AC 3 & AC 4)
create or replace function public.guard_campaign_dispatch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id uuid;
  v_est_paisa bigint;
  v_balance bigint;
begin
  select tenant_id into v_tenant_id
  from public.message_batch
  where id = p_batch_id;

  if v_tenant_id is null then
    raise exception 'CAMPAIGN_NOT_FOUND';
  end if;

  v_est_paisa := public.estimate_campaign_cost(p_batch_id);

  -- Concurrency-safe check with row lock
  select balance_paisa
  into v_balance
  from public.tenant_comm_wallet
  where tenant_id = v_tenant_id
  for update;

  if v_balance is null then
    v_balance := 0;
  end if;

  if v_balance < v_est_paisa then
    raise exception 'INSUFFICIENT_COMM_BALANCE: Campaign requires PKR %, but wallet balance is PKR % (Shortfall: PKR %)',
      to_char(v_est_paisa::numeric / 100, 'FM999,990.00'),
      to_char(v_balance::numeric / 100, 'FM999,990.00'),
      to_char((v_est_paisa - v_balance)::numeric / 100, 'FM999,990.00')
      using errcode = '23514';
  end if;

  return jsonb_build_object(
    'success', true,
    'estimated_paisa', v_est_paisa,
    'balance_before', v_balance
  );
end;
$$;

-- 8. Record Attempt Cost at Provider Acknowledgement (AC 1 & AC 2)
create or replace function public.record_attempt_cost(
  p_attempt_id uuid,
  p_network text default 'all',
  p_conversation_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_attempt record;
  v_message record;
  v_encoding text;
  v_rate_card record;
  v_units int := 1;
  v_cost_paisa bigint := 0;
  v_ledger_id uuid;
begin
  -- Fetch attempt & message details
  select ma.id, ma.message_id, ma.channel, ma.provider_id
  into v_attempt
  from public.message_attempt ma
  where ma.id = p_attempt_id;

  if v_attempt.id is null then
    raise exception 'ATTEMPT_NOT_FOUND';
  end if;

  select m.tenant_id, m.campus_id, m.body, m.segment_count
  into v_message
  from public.message m
  where m.id = v_attempt.message_id;

  -- Determine encoding: ucs2 (Urdu) vs gsm7
  if v_message.body ~ '[\u0600-\u06FF]' then
    v_encoding := 'ucs2';
  else
    v_encoding := 'gsm7';
  end if;

  -- Units: for SMS it is segment_count; for WhatsApp it is 1 conversation
  if v_attempt.channel = 'sms' then
    v_units := coalesce(v_message.segment_count, 1);
  else
    v_units := 1;
  end if;

  -- AC 2: For WhatsApp with conversation_id, check if cost already recorded in 24h
  if v_attempt.channel = 'whatsapp' and p_conversation_id is not null then
    if exists (
      select 1 from public.message_cost_ledger
      where tenant_id = v_message.tenant_id
        and conversation_id = p_conversation_id
    ) then
      return jsonb_build_object(
        'success', true,
        'action', 'deduped_conversation',
        'conversation_id', p_conversation_id,
        'cost_paisa', 0
      );
    end if;
  end if;

  -- Find effective-dated rate card
  select id, rate_paisa, network
  into v_rate_card
  from public.provider_rate_card
  where channel = v_attempt.channel
    and encoding = v_encoding
    and (network = p_network or network = 'all')
    and effective_from <= current_date
    and (effective_to is null or effective_to >= current_date)
  order by (network = p_network) desc, effective_from desc
  limit 1;

  if v_rate_card.id is null then
    raise exception 'NO_EFFECTIVE_RATE_CARD_FOUND';
  end if;

  -- Calculate total cost: rate_paisa * units (AC 1: 3 segments * 120 paisa = 360 paisa)
  v_cost_paisa := (v_rate_card.rate_paisa * v_units);

  -- Insert cost ledger row referencing the rate card version used
  insert into public.message_cost_ledger (
    tenant_id,
    campus_id,
    message_id,
    attempt_id,
    channel,
    conversation_id,
    provider_id,
    currency,
    cost_paisa,
    rate_per_unit,
    rate_card_id,
    units,
    status
  ) values (
    v_message.tenant_id,
    v_message.campus_id,
    v_attempt.message_id,
    v_attempt.id,
    v_attempt.channel,
    p_conversation_id,
    v_attempt.provider_id,
    'PKR',
    v_cost_paisa,
    (v_rate_card.rate_paisa::numeric / 100),
    v_rate_card.id,
    v_units,
    'billed'
  )
  on conflict (tenant_id, conversation_id) where conversation_id is not null do nothing
  returning id into v_ledger_id;

  -- Debit wallet if not deduped
  if v_ledger_id is not null and v_cost_paisa > 0 then
    perform public.debit_comm_wallet(
      v_message.tenant_id,
      v_cost_paisa,
      'Attempt ' || v_attempt.id::text,
      jsonb_build_object('rate_card_id', v_rate_card.id, 'units', v_units)
    );
  end if;

  return jsonb_build_object(
    'success', true,
    'action', 'billed',
    'ledger_id', v_ledger_id,
    'cost_paisa', v_cost_paisa,
    'units', v_units,
    'rate_card_id', v_rate_card.id
  );
end;
$$;

-- 9. Views for Campaign Cost & Monthly Communication Spend
create or replace view public.v_campaign_cost as
select
  m.batch_id as campaign_id,
  m.tenant_id,
  count(distinct m.id) as total_messages,
  sum(cl.units) as total_units,
  sum(cl.cost_paisa) as total_cost_paisa,
  round((sum(cl.cost_paisa)::numeric / 100), 2) as total_cost_pkr
from public.message m
join public.message_cost_ledger cl on cl.message_id = m.id
where m.batch_id is not null
group by m.batch_id, m.tenant_id;

create or replace view public.v_monthly_comm_spend as
select
  cl.tenant_id,
  to_char(cl.created_at, 'YYYY-MM') as billing_month,
  cl.channel,
  sum(cl.units) as total_units,
  sum(cl.cost_paisa) as total_spend_paisa,
  round((sum(cl.cost_paisa)::numeric / 100), 2) as total_spend_pkr
from public.message_cost_ledger cl
group by cl.tenant_id, to_char(cl.created_at, 'YYYY-MM'), cl.channel;

-- 10. RLS: wallet_owner_director_only
alter table public.tenant_comm_wallet enable row level security;
alter table public.tenant_comm_wallet_txn enable row level security;
alter table public.provider_rate_card enable row level security;

create policy "wallet_owner_director_only"
  on public.tenant_comm_wallet
  for all
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'director'))
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'director'))
  );

create policy "wallet_txn_owner_director_read"
  on public.tenant_comm_wallet_txn
  for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'director'))
  );

create policy "rate_card_read"
  on public.provider_rate_card
  for select
  to authenticated
  using (true);

-- Grants
grant select on public.tenant_comm_wallet to authenticated;
grant select on public.tenant_comm_wallet_txn to authenticated;
grant select on public.provider_rate_card to authenticated;
grant select on public.comm_cost_ledger to authenticated;
grant select on public.v_campaign_cost to authenticated;
grant select on public.v_monthly_comm_spend to authenticated;
grant execute on function public.debit_comm_wallet(uuid, bigint, text, jsonb) to authenticated;
grant execute on function public.top_up_comm_wallet(uuid, bigint, text, jsonb) to authenticated;
grant execute on function public.estimate_campaign_cost(uuid) to authenticated;
grant execute on function public.guard_campaign_dispatch(uuid) to authenticated;
grant execute on function public.record_attempt_cost(uuid, text, text) to authenticated;
