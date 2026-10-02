-- ══════════════════════════════════════════════════════════════════════════════
-- Migration: 20260801450000_opt_out_capture_and_suppression.sql
-- Module M: Communication — FR-M11: Opt-out capture and suppression
-- ══════════════════════════════════════════════════════════════════════════════

-- 1. Enhance comm_opt_out table
alter table public.comm_opt_out
  add column if not exists recipient_id uuid,
  add column if not exists source text not null default 'staff',
  add column if not exists created_by uuid references auth.users(id) on delete set null;

-- Audit table for opt-outs and resubscriptions
create table if not exists public.comm_opt_out_audit (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  recipient_phone text not null,
  channel public.comm_channel not null,
  action text not null check (action in ('opt_out', 'resubscribe')),
  actor_id uuid references auth.users(id) on delete set null,
  reason text,
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists idx_comm_opt_out_audit_tenant on public.comm_opt_out_audit(tenant_id, created_at desc);

-- 2. Inbound SMS table (PTA keyword receptor)
create table if not exists public.inbound_sms (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant(id) on delete cascade,
  from_phone text not null,
  to_mask text,
  body text not null,
  raw jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default clock_timestamp()
);

create index if not exists idx_inbound_sms_tenant on public.inbound_sms(tenant_id, received_at desc);
create index if not exists idx_inbound_sms_from on public.inbound_sms(from_phone);

-- 3. Trigger on inbound_sms: AC 1 (STOP / بند keywords automatically suppress)
create or replace function public.tg_inbound_stop_keyword()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_clean text;
begin
  v_clean := trim(upper(NEW.body));
  -- Check English and Urdu STOP keywords
  if v_clean in ('STOP', 'UNSUBSCRIBE', 'QUIT', 'END', 'CANCEL', 'بند', 'روکیں', 'بند کرو') then
    insert into public.comm_opt_out (
      tenant_id,
      recipient_phone,
      channel,
      reason,
      source,
      opted_out_at
    ) values (
      NEW.tenant_id,
      NEW.from_phone,
      'sms'::public.comm_channel,
      'Inbound keyword: ' || NEW.body,
      'inbound_stop_keyword',
      clock_timestamp()
    )
    on conflict (tenant_id, recipient_phone, channel) do update
    set reason = 'Inbound keyword: ' || NEW.body,
        source = 'inbound_stop_keyword',
        opted_out_at = clock_timestamp();

    -- Log audit row
    insert into public.comm_opt_out_audit (
      tenant_id,
      recipient_phone,
      channel,
      action,
      reason
    ) values (
      NEW.tenant_id,
      NEW.from_phone,
      'sms'::public.comm_channel,
      'opt_out',
      'Inbound keyword: ' || NEW.body
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_inbound_stop_keyword on public.inbound_sms;
create trigger trg_inbound_stop_keyword
  after insert on public.inbound_sms
  for each row execute function public.tg_inbound_stop_keyword();

-- 4. Suppression check function: AC 2 (Transactional messages exempt!)
create or replace function public.is_suppressed(
  p_tenant_id uuid,
  p_phone text,
  p_channel public.comm_channel,
  p_message_class text default 'marketing'
)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  -- AC 2: Transactional & Emergency messages are strictly exempt from marketing suppression
  if lower(coalesce(p_message_class, '')) in ('transactional', 'emergency', 'fee', 'attendance') then
    return false;
  end if;

  if p_phone is null or trim(p_phone) = '' then
    return false;
  end if;

  return exists (
    select 1
    from public.comm_opt_out
    where tenant_id = p_tenant_id
      and recipient_phone = p_phone
      and channel = p_channel
  );
end;
$$;

-- 5. Resubscribe function: AC 3 (clears suppression, logs actor id and timestamp)
create or replace function public.resubscribe_recipient(
  p_tenant_id uuid,
  p_phone text,
  p_channel public.comm_channel,
  p_actor_id uuid default null,
  p_reason text default 'Parent portal toggle'
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Delete from suppression table
  delete from public.comm_opt_out
  where tenant_id = p_tenant_id
    and recipient_phone = p_phone
    and channel = p_channel;

  -- Audit log
  insert into public.comm_opt_out_audit (
    tenant_id,
    recipient_phone,
    channel,
    action,
    actor_id,
    reason,
    created_at
  ) values (
    p_tenant_id,
    p_phone,
    p_channel,
    'resubscribe',
    p_actor_id,
    p_reason,
    clock_timestamp()
  );

  return true;
end;
$$;

-- 6. Campaign Preview Function: AC 4 (Shows sendable vs suppressed counts separately)
create or replace function public.preview_campaign_suppression(p_batch_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant_id uuid;
  v_channel public.comm_channel;
  v_total int := 0;
  v_suppressed int := 0;
  v_sendable int := 0;
begin
  select tenant_id, channel
  into v_tenant_id, v_channel
  from public.message_batch
  where id = p_batch_id;

  if v_tenant_id is null then
    raise exception 'CAMPAIGN_NOT_FOUND';
  end if;

  select
    count(*),
    count(*) filter (where public.is_suppressed(m.tenant_id, m.recipient_phone, m.channel, m.message_class)),
    count(*) filter (where not public.is_suppressed(m.tenant_id, m.recipient_phone, m.channel, m.message_class))
  into v_total, v_suppressed, v_sendable
  from public.message m
  where m.batch_id = p_batch_id;

  return jsonb_build_object(
    'total', coalesce(v_total, 0),
    'suppressed', coalesce(v_suppressed, 0),
    'sendable', coalesce(v_sendable, 0)
  );
end;
$$;

-- 7. Apply suppression at dispatch time (skips opted-out non-exempt messages)
create or replace function public.apply_dispatch_suppression(p_batch_id uuid)
returns table (
  skipped_count int
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_count int := 0;
begin
  update public.message m
  set
    status = 'cancelled'::public.message_status,
    final_status = 'cancelled'::public.message_status,
    metadata = coalesce(m.metadata, '{}'::jsonb) || jsonb_build_object('skip_reason', 'opted_out', 'skipped_at', clock_timestamp())
  where m.batch_id = p_batch_id
    and m.status = 'queued'::public.message_status
    and public.is_suppressed(m.tenant_id, m.recipient_phone, m.channel, m.message_class);

  get diagnostics v_count = row_count;
  return query select v_count;
end;
$$;

-- 8. RLS and Grants
alter table public.inbound_sms enable row level security;
alter table public.comm_opt_out_audit enable row level security;

create policy "inbound_sms_tenant_read"
  on public.inbound_sms for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal', 'admin', 'coordinator'))
  );

create policy "inbound_sms_insert"
  on public.inbound_sms for insert
  to authenticated, anon
  with check (true);

create policy "comm_opt_out_audit_tenant_read"
  on public.comm_opt_out_audit for select
  to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner', 'principal', 'admin'))
  );

grant select, insert on public.inbound_sms to authenticated, anon;
grant select on public.comm_opt_out_audit to authenticated;
grant execute on function public.is_suppressed(uuid, text, public.comm_channel, text) to authenticated, anon;
grant execute on function public.resubscribe_recipient(uuid, text, public.comm_channel, uuid, text) to authenticated;
grant execute on function public.preview_campaign_suppression(uuid) to authenticated;
grant execute on function public.apply_dispatch_suppression(uuid) to authenticated;
