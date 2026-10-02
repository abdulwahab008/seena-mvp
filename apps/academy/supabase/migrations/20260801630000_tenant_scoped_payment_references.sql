-- FR-K21/K22 fix: a 1LINK voucher reference IS the challan number (AC), and
-- challan numbers repeat across schools (each school's counter starts at one).
-- The intent reference must therefore be unique per tenant, not globally, and
-- the webhook must resolve the intent inside the tenant that owns the
-- merchant id the callback was signed for.

drop index if exists public.uq_payment_intent_gateway_ref;
create unique index uq_payment_intent_tenant_gateway_ref on public.payment_intent (tenant_id, gateway, gateway_ref);

drop function if exists public.ingest_payment_webhook(text, text, jsonb, text, boolean);

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
   where tenant_id = v_event.tenant_id and gateway = v_event.gateway and gateway_ref = v_ref
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

create function public.ingest_payment_webhook(
  p_tenant_id uuid, p_gateway text, p_txn_id text, p_payload jsonb, p_raw text, p_signature_valid boolean
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

  insert into public.payment_webhook_event (tenant_id, gateway, gateway_txn_id, payload, raw_body, raw_body_sha256, signature_valid)
  values (p_tenant_id, p_gateway, p_txn_id, p_payload, left(p_raw, 16384), v_hash, true)
  on conflict (gateway, gateway_txn_id) where signature_valid and gateway_txn_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('result', 'duplicate');
  end if;

  v_state := app.fn_process_payment_event(v_id);
  return jsonb_build_object('result', v_state, 'event_id', v_id);
end;
$$;
revoke execute on function public.ingest_payment_webhook(uuid, text, text, jsonb, text, boolean) from public, anon, authenticated;
grant execute on function public.ingest_payment_webhook(uuid, text, text, jsonb, text, boolean) to service_role;
