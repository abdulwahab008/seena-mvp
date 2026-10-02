-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M02: Per-recipient channel fallback chain
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(19);

-- ─── 1. Setup Fixtures ─────────────────────────────────────────────────
select public.provision_tenant('test-fallback-chain', 'Fallback Academy', 'owner@fallback.test');
select id as tenant_id from public.tenant where slug = 'test-fallback-chain' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'comm_channel_chain', 'Table comm_channel_chain exists');
select has_table('public', 'comm_opt_out', 'Table comm_opt_out exists');
select has_table('public', 'message_cost_ledger', 'Table message_cost_ledger exists');

select has_column('public', 'message_attempt', 'channel', 'message_attempt has channel column');
select has_column('public', 'message_attempt', 'escalated_from_attempt_id', 'message_attempt has escalated_from_attempt_id column');
select has_column('public', 'message_attempt', 'skip_reason', 'message_attempt has skip_reason column');
select has_column('public', 'message', 'final_status', 'message has final_status column');
select has_column('public', 'message', 'message_class', 'message has message_class column');

-- ─── 3. Default Chain Fallback ─────────────────────────────────────────
-- Verify default channel chain resolution for tenant
select is(
  (select ordered_channels from public.get_channel_chain(:'tenant_id'::uuid, 'default')),
  array['whatsapp', 'sms']::public.comm_channel[],
  'Default channel chain for tenant resolves to [whatsapp, sms]'
);

-- ─── 4. FR-M02 AC 1: Immediate Failure Receipt & Dual Cost Rows ────────
-- Given chain [WhatsApp, SMS] and a WhatsApp 'undelivered' receipt,
-- when the receipt is applied, then an SMS attempt is created within 60 seconds
-- and two cost rows exist for the message.

-- Create a WhatsApp message
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923001234567', 'whatsapp',
  'Dear Guardian, your child was marked absent today.', 'sending', 'default'
) returning id as msg_ac1_id \gset

-- Create initial WhatsApp attempt
insert into public.message_attempt (
  message_id, attempt_number, channel, status, dispatched_at
) values (
  :'msg_ac1_id'::uuid, 1, 'whatsapp', 'sent', clock_timestamp()
) returning id as att_ac1_id \gset

-- Record initial cost for WhatsApp attempt
select public.record_message_cost(:'msg_ac1_id'::uuid, :'att_ac1_id'::uuid, 'whatsapp', 150, 1);

-- Apply 'undelivered' receipt to WhatsApp attempt
select is(
  public.apply_receipt(:'att_ac1_id'::uuid, 'undelivered', 'WHATSAPP_INVALID_USER'),
  'undelivered'::public.attempt_status,
  'FR-M02 AC 1: Receipt status applied as undelivered'
);

-- Verify that an SMS attempt was automatically created
select is(
  (select count(*) from public.message_attempt where message_id = :'msg_ac1_id'::uuid and channel = 'sms'),
  1::bigint,
  'FR-M02 AC 1: Fallback created an SMS attempt'
);

-- Verify that exactly two cost rows exist for the message (WhatsApp + SMS)
select is(
  (select count(*) from public.message_cost_ledger where message_id = :'msg_ac1_id'::uuid),
  2::bigint,
  'FR-M02 AC 1: Exactly two cost rows exist for the message (WhatsApp + SMS)'
);

-- ─── 5. FR-M02 AC 2: Delivery Window Timeout & Late Delivered Receipt ───
-- Given WhatsApp returns 'sent' but no 'delivered' within 15 minutes,
-- when the window elapses, then SMS fallback fires, and a late WhatsApp 'delivered'
-- at minute 20 does not cancel or reverse the SMS attempt.

-- Create custom fast timeout chain for testing: WhatsApp wait = 1 second
insert into public.comm_channel_chain (
  tenant_id, message_class, ordered_channels, wait_seconds
) values (
  :'tenant_id'::uuid, 'billing_reminder',
  array['whatsapp', 'sms']::public.comm_channel[],
  '{"whatsapp": 1, "sms": 60}'::jsonb
);

-- Create message for billing reminder
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923009988776', 'whatsapp',
  'Dear Guardian, monthly fee challan is due.', 'sending', 'billing_reminder'
) returning id as msg_ac2_id \gset

-- Create initial attempt dispatched 2 seconds ago (exceeding 1s timeout window)
insert into public.message_attempt (
  message_id, attempt_number, channel, status, dispatched_at
) values (
  :'msg_ac2_id'::uuid, 1, 'whatsapp', 'sent', clock_timestamp() - interval '2 seconds'
) returning id as att_ac2_id \gset

-- Run timeout scanner
select ok(
  exists (
    select 1
    from public.escalate_timed_out_attempts(:'tenant_id'::uuid)
    where message_id = :'msg_ac2_id'::uuid and escalated_to_channel = 'sms'
  ),
  'FR-M02 AC 2: Timeout window scanner detected expired attempt and escalated to SMS'
);

-- Verify WhatsApp attempt was marked 'timeout'
select is(
  (select status from public.message_attempt where id = :'att_ac2_id'::uuid),
  'timeout'::public.attempt_status,
  'FR-M02 AC 2: Original WhatsApp attempt is marked timeout'
);

-- Apply late 'delivered' receipt to WhatsApp attempt at a later time
select public.apply_receipt(:'att_ac2_id'::uuid, 'delivered');

-- Verify SMS fallback attempt is NOT cancelled or reversed
select ok(
  exists (
    select 1
    from public.message_attempt
    where message_id = :'msg_ac2_id'::uuid
      and channel = 'sms'
      and status in ('sending', 'sent')
  ),
  'FR-M02 AC 2: Late WhatsApp delivered receipt did not cancel or reverse the SMS attempt'
);

-- ─── 6. FR-M02 AC 3: Opt-Out Capture & Hop Skipping ─────────────────────
-- Given the recipient has opted out of SMS but not WhatsApp,
-- when the chain escalates, then the SMS hop is skipped with reason 'opted_out'
-- and message.final_status is set to 'exhausted' not 'failed'.

-- Register SMS opt-out for +923114445555
insert into public.comm_opt_out (tenant_id, recipient_phone, channel, reason)
values (:'tenant_id'::uuid, '+923114445555', 'sms', 'Parent opted out via USSD STOP');

-- Create WhatsApp message
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923114445555', 'whatsapp',
  'Dear Guardian, sports day notice.', 'sending', 'default'
) returning id as msg_ac3_id \gset

insert into public.message_attempt (
  message_id, attempt_number, channel, status, dispatched_at
) values (
  :'msg_ac3_id'::uuid, 1, 'whatsapp', 'sent', clock_timestamp()
) returning id as att_ac3_id \gset

-- Apply undelivered to WhatsApp attempt -> triggers escalation to SMS
select public.apply_receipt(:'att_ac3_id'::uuid, 'undelivered');

-- Verify SMS hop was skipped with reason 'opted_out'
select is(
  (select skip_reason from public.message_attempt where message_id = :'msg_ac3_id'::uuid and channel = 'sms'),
  'opted_out',
  'FR-M02 AC 3: SMS attempt was recorded as skipped with skip_reason = opted_out'
);

-- Verify message final_status is 'exhausted'
select is(
  (select final_status from public.message where id = :'msg_ac3_id'::uuid),
  'exhausted'::public.message_status,
  'FR-M02 AC 3: Message final_status is set to exhausted (not failed)'
);

-- ─── 7. FR-M02 AC 4: 3-Channel Chain Exhaustion ─────────────────────────
-- Given a chain of 3 channels all failing, when the last attempt terminates,
-- then exactly 3 attempt rows exist and the campaign report counts the recipient once as unreached.

-- Configure 3-channel chain [whatsapp, sms, push]
insert into public.comm_channel_chain (
  tenant_id, message_class, ordered_channels, wait_seconds
) values (
  :'tenant_id'::uuid, 'tri_channel_alert',
  array['whatsapp', 'sms', 'push']::public.comm_channel[],
  '{"whatsapp": 300, "sms": 300, "push": 300}'::jsonb
);

insert into public.message (
  tenant_id, campus_id, recipient_phone, recipient_id, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923221112233', gen_random_uuid(), 'whatsapp',
  'Critical Alert: School closed tomorrow due to heavy rain.', 'sending', 'tri_channel_alert'
) returning id as msg_ac4_id \gset

-- Hop 1: WhatsApp fails
insert into public.message_attempt (
  message_id, attempt_number, channel, status, dispatched_at
) values (
  :'msg_ac4_id'::uuid, 1, 'whatsapp', 'sent', clock_timestamp()
) returning id as att_ac4_1_id \gset

select public.apply_receipt(:'att_ac4_1_id'::uuid, 'undelivered');

-- Hop 2: SMS fails
select id as att_ac4_2_id
from public.message_attempt
where message_id = :'msg_ac4_id'::uuid and channel = 'sms' \gset

select public.apply_receipt(:'att_ac4_2_id'::uuid, 'undelivered');

-- Hop 3: Push fails
select id as att_ac4_3_id
from public.message_attempt
where message_id = :'msg_ac4_id'::uuid and channel = 'push' \gset

select public.apply_receipt(:'att_ac4_3_id'::uuid, 'failed');

-- Verify exactly 3 attempt rows exist for the message
select is(
  (select count(*) from public.message_attempt where message_id = :'msg_ac4_id'::uuid),
  3::bigint,
  'FR-M02 AC 4: Exactly 3 attempt rows exist across WhatsApp, SMS, and Push'
);

-- Verify message final status is exhausted
select is(
  (select final_status from public.message where id = :'msg_ac4_id'::uuid),
  'exhausted'::public.message_status,
  'FR-M02 AC 4: Message final_status is marked exhausted after all 3 channels fail'
);

select * from finish();
rollback;
