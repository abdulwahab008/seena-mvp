-- FR-K22: idempotent, signature-verified payment webhooks.
--
-- Gateways have no Supabase JWT, so the HMAC check in the Next.js route is the
-- only authentication and runs before ANY database write except raw event
-- capture. Everything here is service_role-only; RLS denies every client role.
--
-- Exactly-once is enforced three ways: a partial unique index on
-- (gateway, gateway_txn_id) for validly-signed events, the intent's terminal
-- state, and a unique index on online fee_payment references. A forged event
-- cannot squat a real transaction id: the unique index covers only events
-- whose signature verified.

create table public.payment_webhook_event (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid references public.tenant(id) on delete set null,
  gateway         text not null check (gateway in ('jazzcash', 'easypaisa', 'onelink')),
  gateway_txn_id  text,
  payload         jsonb,
  raw_body        text,
  raw_body_sha256 text not null,
  signature_valid boolean not null,
  status          text not null default 'received'
                    check (status in ('received', 'processed', 'duplicate', 'signature_invalid', 'orphan')),
  processed_at    timestamptz,
  error_text      text,
  created_at      timestamptz not null default clock_timestamp()
);

create unique index payment_webhook_txn_uq on public.payment_webhook_event (gateway, gateway_txn_id)
  where signature_valid and gateway_txn_id is not null;
create index idx_payment_webhook_orphan on public.payment_webhook_event (created_at) where status = 'orphan';
create index idx_payment_webhook_invalid on public.payment_webhook_event (gateway, created_at) where status = 'signature_invalid';

create table public.payment_alert (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  kind          text not null check (kind in ('amount_mismatch', 'overpayment', 'late_success')),
  intent_id     uuid references public.payment_intent(id) on delete set null,
  event_id      uuid references public.payment_webhook_event(id) on delete set null,
  expected_paisa bigint,
  received_paisa bigint,
  detail        text,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);
create index idx_payment_alert_scope on public.payment_alert (tenant_id, campus_id, created_at desc);

create unique index uq_fee_payment_online_ref on public.fee_payment (tenant_id, reference_no)
  where mode = 'online' and reference_no is not null;

alter table public.payment_webhook_event enable row level security;
alter table public.payment_alert enable row level security;

create policy payment_webhook_event_service_only on public.payment_webhook_event
  for all to authenticated using (false) with check (false);

create policy payment_alert_finance_read on public.payment_alert
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

-- Posts a gateway-confirmed payment through the canonical money path
-- (record_payment -> ledger credit -> oldest-first allocation) by acting as a
-- system accountant for exactly this transaction, then restoring the claims.
create or replace function app.fn_post_online_payment(p_tenant_id uuid, p_enrolment_id uuid, p_amount bigint, p_reference text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev text := current_setting('request.jwt.claims', true);
  v_id   uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('tenant_id', p_tenant_id, 'app_role', 'accountant')::text, true);
  v_id := public.record_payment(p_enrolment_id, p_amount, 'online'::public.fee_payment_mode, p_reference, current_date);
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_id;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function app.fn_post_online_payment(uuid, uuid, bigint, text) from public, anon, authenticated;

create or replace function app.fn_process_payment_event(p_event_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event    public.payment_webhook_event%rowtype;
  v_intent   public.payment_intent%rowtype;
  v_ref      text;
  v_ok       boolean;
  v_amount   bigint;
  v_was_expired boolean;
  v_payment  uuid;
  v_unalloc  bigint;
begin
  select * into v_event from public.payment_webhook_event where id = p_event_id for update;
  if not found or v_event.status not in ('received', 'orphan') then
    return coalesce(v_event.status, 'missing');
  end if;

  v_ref := v_event.payload ->> 'gateway_ref';
  select * into v_intent from public.payment_intent
   where gateway = v_event.gateway and gateway_ref = v_ref
   for update;

  if not found then
    -- The callback beat the initiating transaction: keep it, retry shortly.
    update public.payment_webhook_event set status = 'orphan' where id = p_event_id;
    return 'orphan';
  end if;

  v_ok := lower(coalesce(v_event.payload ->> 'status', '')) in ('success', 'succeeded', 'paid');

  if v_intent.status = 'succeeded' then
    update public.payment_webhook_event
       set status = 'duplicate', tenant_id = v_intent.tenant_id, processed_at = now()
     where id = p_event_id;
    return 'duplicate';
  end if;

  if not v_ok then
    update public.payment_intent set status = 'failed', updated_at = now()
     where id = v_intent.id and status in ('initiated', 'pending');
    update public.payment_webhook_event
       set status = 'processed', tenant_id = v_intent.tenant_id, processed_at = now()
     where id = p_event_id;
    return 'processed';
  end if;

  begin
    v_amount := (v_event.payload ->> 'amount_paisa')::bigint;
  exception when others then
    v_amount := null;
  end;
  if v_amount is null or v_amount <= 0 then
    update public.payment_webhook_event
       set status = 'processed', tenant_id = v_intent.tenant_id, processed_at = now(), error_text = 'INVALID_AMOUNT'
     where id = p_event_id;
    return 'processed';
  end if;

  v_was_expired := v_intent.status = 'expired';
  v_payment := app.fn_post_online_payment(v_intent.tenant_id, v_intent.enrolment_id, v_amount, v_event.gateway_txn_id);

  update public.payment_intent set status = 'succeeded', updated_at = now() where id = v_intent.id;

  if v_amount <> v_intent.amount_paisa then
    insert into public.payment_alert (tenant_id, campus_id, kind, intent_id, event_id, expected_paisa, received_paisa, detail)
    values (v_intent.tenant_id, v_intent.campus_id, case when v_amount < v_intent.amount_paisa then 'amount_mismatch' else 'overpayment' end,
            v_intent.id, p_event_id, v_intent.amount_paisa, v_amount, 'Posted as received; challan not marked paid unless fully covered');
  end if;

  select v_amount - coalesce(sum(amount_paisa), 0) into v_unalloc from public.fee_payment_allocation where payment_id = v_payment;
  if v_was_expired or v_unalloc > 0 then
    insert into public.payment_alert (tenant_id, campus_id, kind, intent_id, event_id, expected_paisa, received_paisa, detail)
    values (v_intent.tenant_id, v_intent.campus_id, 'late_success', v_intent.id, p_event_id, v_intent.amount_paisa, v_amount,
            case when v_was_expired then 'Success callback arrived after the intent expired' else 'Part of the payment could not be allocated to an open challan' end);
  end if;

  update public.payment_webhook_event
     set status = 'processed', tenant_id = v_intent.tenant_id, processed_at = now()
   where id = p_event_id;
  return 'processed';
end;
$$;
revoke execute on function app.fn_process_payment_event(uuid) from public, anon, authenticated;

create or replace function public.ingest_payment_webhook(
  p_gateway text, p_txn_id text, p_payload jsonb, p_raw text, p_signature_valid boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash  text := encode(extensions.digest(coalesce(p_raw, ''), 'sha256'), 'hex');
  v_id    uuid;
  v_state text;
begin
  if not p_signature_valid then
    -- Unauthenticated input: cap what it can write.
    if (select count(*) from public.payment_webhook_event
         where gateway = p_gateway and status = 'signature_invalid' and created_at > now() - interval '1 minute') >= 100 then
      return jsonb_build_object('result', 'rate_limited');
    end if;
    insert into public.payment_webhook_event (gateway, gateway_txn_id, raw_body, raw_body_sha256, signature_valid, status)
    values (p_gateway, null, left(p_raw, 16384), v_hash, false, 'signature_invalid');
    return jsonb_build_object('result', 'signature_invalid');
  end if;

  insert into public.payment_webhook_event (gateway, gateway_txn_id, payload, raw_body, raw_body_sha256, signature_valid)
  values (p_gateway, p_txn_id, p_payload, left(p_raw, 16384), v_hash, true)
  on conflict (gateway, gateway_txn_id) where signature_valid and gateway_txn_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('result', 'duplicate');
  end if;

  v_state := app.fn_process_payment_event(v_id);
  return jsonb_build_object('result', v_state, 'event_id', v_id);
end;
$$;
revoke execute on function public.ingest_payment_webhook(text, text, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.ingest_payment_webhook(text, text, jsonb, text, boolean) to service_role;

-- Reprocesses callbacks that arrived before their intent was visible.
create or replace function public.retry_orphan_webhooks()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e record;
  v_n int := 0;
begin
  for v_e in select id from public.payment_webhook_event where status = 'orphan' and created_at > now() - interval '24 hours' order by created_at loop
    if app.fn_process_payment_event(v_e.id) = 'processed' then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.retry_orphan_webhooks() from public, anon, authenticated;
grant execute on function public.retry_orphan_webhooks() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('fees-retry-orphan-webhooks', '*/5 * * * *', 'select public.retry_orphan_webhooks();');
  end if;
exception
  when others then null;
end;
$$;
