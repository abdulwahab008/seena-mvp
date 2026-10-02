-- FR-M01: Unified outbound message outbox
--
-- Features implemented:
--   * Central message outbox queue (public.message) supporting multi-channel dispatch
--     (SMS, WhatsApp, Email, Push) with campus and tenant scoping.
--   * Concurrency-safe queue batch claiming using FOR UPDATE SKIP LOCKED
--     (claim_message_batch) ensuring workers claim mutually exclusive sets of messages
--     without duplicates.
--   * Pakistani SMS aggregator timeout resilience: attempts timing out after 30s
--     are recorded as 'unknown', and resolved by provider status lookup
--     (resolve_unknown_attempt) rather than blind-retried.
--   * Idempotency protection via unique partial index on (tenant_id, idempotency_key).
--   * Strict RLS: user inserting a message whose campus_id is not in their JWT
--     claims is rejected with SQLSTATE 42501.
--   * Secure provider credential store (comm_provider_credential) storing vault references,
--     restricted to owner and super_admin roles.

-- 1. Custom Types
do $$
begin
  if not exists (select 1 from pg_type where typname = 'comm_channel') then
    create type public.comm_channel as enum ('sms', 'whatsapp', 'email', 'push');
  end if;

  if not exists (select 1 from pg_type where typname = 'message_status') then
    create type public.message_status as enum ('queued', 'claimed', 'sending', 'delivered', 'failed', 'cancelled', 'unknown');
  end if;

  if not exists (select 1 from pg_type where typname = 'attempt_status') then
    create type public.attempt_status as enum ('sending', 'sent', 'delivered', 'failed', 'unknown', 'timeout');
  end if;

  if not exists (select 1 from pg_type where typname = 'comm_recipient_type') then
    create type public.comm_recipient_type as enum ('parent', 'guardian', 'student', 'staff', 'custom');
  end if;
end $$;

-- 2. Communication Providers
create table if not exists public.comm_provider (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  name             text not null,
  channel          public.comm_channel not null,
  is_active        boolean not null default true,
  default_priority int not null default 1,
  config_schema    jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default clock_timestamp(),
  updated_at       timestamptz not null default clock_timestamp()
);

-- Seed standard Pakistani & international aggregators
insert into public.comm_provider (code, name, channel, default_priority) values
  ('jazz_sms', 'Jazz SMS Aggregator', 'sms', 1),
  ('zong_sms', 'Zong Corporate SMS', 'sms', 2),
  ('telenor_sms', 'Telenor Messaging Portal', 'sms', 3),
  ('whatsapp_cloud', 'WhatsApp Cloud API', 'whatsapp', 1),
  ('smtp_relay', 'Institutional SMTP Relay', 'email', 1),
  ('firebase_fcm', 'Firebase Cloud Messaging', 'push', 1)
on conflict (code) do nothing;

-- 3. Provider Credentials (Secrets referenced by Vault ref, never plaintext)
create table if not exists public.comm_provider_credential (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  provider_id          uuid not null references public.comm_provider(id) on delete cascade,
  credential_vault_ref text not null,
  sender_id            text, -- e.g. alphanumeric mask like 'SEENA' or WhatsApp business phone number
  config               jsonb not null default '{}'::jsonb,
  is_active            boolean not null default true,
  created_at           timestamptz not null default clock_timestamp(),
  updated_at           timestamptz not null default clock_timestamp(),
  constraint uq_provider_credential_tenant unique (tenant_id, provider_id)
);

-- 4. Message Batches
create table if not exists public.message_batch (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  title        text not null,
  channel      public.comm_channel not null,
  created_by   uuid references auth.users(id) on delete set null,
  total_count  int not null default 0,
  queued_count int not null default 0,
  sent_count   int not null default 0,
  failed_count int not null default 0,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp()
);

-- 5. Outbound Message Queue
create table if not exists public.message (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  batch_id        uuid references public.message_batch(id) on delete set null,
  recipient_type  public.comm_recipient_type not null default 'guardian',
  recipient_id    uuid,
  recipient_phone text,
  recipient_email text,
  channel         public.comm_channel not null default 'sms',
  sender_id       text,
  subject         text,
  body            text not null,
  template_id     uuid,
  status          public.message_status not null default 'queued',
  scheduled_at    timestamptz not null default clock_timestamp(),
  claimed_at      timestamptz,
  claimed_by      uuid,
  idempotency_key text,
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default clock_timestamp(),
  updated_at      timestamptz not null default clock_timestamp(),
  constraint chk_message_recipient_contact check (
    (channel in ('sms', 'whatsapp') and recipient_phone is not null) or
    (channel = 'email' and recipient_email is not null) or
    (channel = 'push' and recipient_id is not null)
  )
);

-- 6. Message Dispatch Attempts
create table if not exists public.message_attempt (
  id             uuid primary key default gen_random_uuid(),
  message_id     uuid not null references public.message(id) on delete cascade,
  attempt_number int not null default 1,
  provider_id    uuid references public.comm_provider(id) on delete set null,
  provider_ref   text,
  status         public.attempt_status not null default 'sending',
  error_code     text,
  error_message  text,
  raw_response   jsonb,
  dispatched_at  timestamptz not null default clock_timestamp(),
  completed_at   timestamptz,
  created_at     timestamptz not null default clock_timestamp(),
  constraint uq_message_attempt_num unique (message_id, attempt_number)
);

-- 7. High Performance Partial Indexes
create index if not exists idx_message_queued
  on public.message (status, scheduled_at)
  where status = 'queued';

create unique index if not exists idx_message_idempotency
  on public.message (tenant_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_message_attempt_provider_ref
  on public.message_attempt (provider_ref)
  where provider_ref is not null;

create index if not exists idx_message_tenant_campus
  on public.message (tenant_id, campus_id, created_at desc);

create index if not exists idx_message_batch
  on public.message (batch_id)
  where batch_id is not null;

create index if not exists idx_message_attempt_msg
  on public.message_attempt (message_id);

-- 8. Audit Triggers
create trigger trg_comm_provider_credential_audit
  after insert or update or delete on public.comm_provider_credential
  for each row execute function app.tg_audit_row();

create trigger trg_message_batch_audit
  after insert or update or delete on public.message_batch
  for each row execute function app.tg_audit_row();

create trigger trg_message_audit
  after insert or update or delete on public.message
  for each row execute function app.tg_audit_row();

-- 9. Concurrency & Queue Dispatch Worker Function
create or replace function public.claim_message_batch(
  p_worker_id uuid,
  p_limit int default 50,
  p_tenant_id uuid default null,
  p_channel public.comm_channel default null
)
returns setof public.message
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := coalesce(p_limit, 50);
begin
  if v_limit < 1 then
    v_limit := 1;
  elsif v_limit > 500 then
    v_limit := 500;
  end if;

  return query
  with locked_messages as (
    select id
    from public.message
    where status = 'queued'
      and scheduled_at <= clock_timestamp()
      and (p_tenant_id is null or tenant_id = p_tenant_id)
      and (p_channel is null or channel = p_channel)
    order by scheduled_at asc, id asc
    limit v_limit
    for update skip locked
  )
  update public.message m
  set status = 'claimed',
      claimed_at = clock_timestamp(),
      claimed_by = p_worker_id,
      updated_at = clock_timestamp()
  from locked_messages lm
  where m.id = lm.id
  returning m.*;
end;
$$;

-- 10. Record Attempt Function
create or replace function public.record_message_attempt(
  p_message_id uuid,
  p_provider_id uuid,
  p_status public.attempt_status,
  p_provider_ref text default null,
  p_error_code text default null,
  p_error_message text default null,
  p_raw_response jsonb default null
)
returns public.message_attempt
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next_attempt int;
  v_attempt public.message_attempt;
  v_msg_status public.message_status;
begin
  select coalesce(max(attempt_number), 0) + 1
  into v_next_attempt
  from public.message_attempt
  where message_id = p_message_id;

  insert into public.message_attempt (
    message_id,
    attempt_number,
    provider_id,
    provider_ref,
    status,
    error_code,
    error_message,
    raw_response,
    completed_at
  ) values (
    p_message_id,
    v_next_attempt,
    p_provider_id,
    p_provider_ref,
    p_status,
    p_error_code,
    p_error_message,
    p_raw_response,
    case when p_status in ('sent', 'delivered', 'failed', 'timeout') then clock_timestamp() else null end
  )
  returning * into v_attempt;

  v_msg_status := case p_status
    when 'delivered' then 'delivered'::public.message_status
    when 'sent' then 'sending'::public.message_status
    when 'failed' then 'failed'::public.message_status
    when 'unknown' then 'unknown'::public.message_status
    when 'timeout' then 'unknown'::public.message_status
    else 'sending'::public.message_status
  end;

  update public.message
  set status = v_msg_status,
      updated_at = clock_timestamp()
  where id = p_message_id;

  return v_attempt;
end;
$$;

-- 11. Timeout & Unknown Attempt Resolution Function
create or replace function public.resolve_unknown_attempt(
  p_attempt_id uuid,
  p_resolved_status public.attempt_status,
  p_provider_ref text default null,
  p_raw_response jsonb default null
)
returns public.message_attempt
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attempt public.message_attempt;
  v_msg_status public.message_status;
begin
  update public.message_attempt
  set status = p_resolved_status,
      provider_ref = coalesce(p_provider_ref, provider_ref),
      raw_response = coalesce(p_raw_response, raw_response),
      completed_at = clock_timestamp()
  where id = p_attempt_id
  returning * into v_attempt;

  if not found then
    raise exception 'Attempt % not found', p_attempt_id;
  end if;

  v_msg_status := case p_resolved_status
    when 'delivered' then 'delivered'::public.message_status
    when 'sent' then 'sending'::public.message_status
    when 'failed' then 'failed'::public.message_status
    else 'unknown'::public.message_status
  end;

  update public.message
  set status = v_msg_status,
      updated_at = clock_timestamp()
  where id = v_attempt.message_id;

  return v_attempt;
end;
$$;

-- 12. Row Level Security Policies
alter table public.comm_provider enable row level security;
alter table public.comm_provider_credential enable row level security;
alter table public.message_batch enable row level security;
alter table public.message enable row level security;
alter table public.message_attempt enable row level security;

-- comm_provider policies
create policy comm_provider_read on public.comm_provider
  for select to authenticated
  using (is_active = true or app.auth_role() in ('super_admin', 'owner'));

create policy comm_provider_admin on public.comm_provider
  for all to authenticated
  using (app.auth_role() in ('super_admin', 'owner'))
  with check (app.auth_role() in ('super_admin', 'owner'));

-- comm_provider_credential policies (strictly owner & super_admin)
create policy comm_provider_credential_owner on public.comm_provider_credential
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner')
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner')
  );

-- message_batch policies
create policy message_batch_read on public.message_batch
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create policy message_batch_write on public.message_batch
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

-- message policies (AC 3: campus_id must be in JWT campus_ids[])
create policy message_read on public.message
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create policy message_insert on public.message
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create policy message_update on public.message
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

-- message_attempt policies
create policy message_attempt_read on public.message_attempt
  for select to authenticated
  using (
    exists (
      select 1 from public.message m
      where m.id = message_id
        and m.tenant_id = app.auth_tenant_id()
        and (
          app.auth_role() in ('super_admin', 'owner')
          or m.campus_id = any(app.auth_campus_ids())
        )
    )
  );

create policy message_attempt_write on public.message_attempt
  for all to authenticated
  using (
    exists (
      select 1 from public.message m
      where m.id = message_id
        and m.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner')
    )
  )
  with check (
    exists (
      select 1 from public.message m
      where m.id = message_id
        and m.tenant_id = app.auth_tenant_id()
        and app.auth_role() in ('super_admin', 'owner')
    )
  );

-- Grants
grant select on public.comm_provider to authenticated;
grant all on public.comm_provider_credential to authenticated;
grant all on public.message_batch to authenticated;
grant all on public.message to authenticated;
grant all on public.message_attempt to authenticated;
grant execute on function public.claim_message_batch to authenticated, service_role;
grant execute on function public.record_message_attempt to authenticated, service_role;
grant execute on function public.resolve_unknown_attempt to authenticated, service_role;
