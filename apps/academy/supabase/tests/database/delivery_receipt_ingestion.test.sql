-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M09: Delivery receipt ingestion
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(12);

-- ─── 1. Setup Test Tenant & Fixtures ──────────────────────────────────────
select public.provision_tenant('test-comm-dlr', 'Delivery Receipt Academy', 'owner@dlr.test');
select id as tenant_id from public.tenant where slug = 'test-comm-dlr' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

select gen_random_uuid() as admin_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_id', 'owner@dlr.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_id', :'tenant_id', 'owner', 'Owner Officer');

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'admin_id',
    'email', 'owner@dlr.test',
    'app_metadata', json_build_object('role', 'authenticated')
  )::text,
  true
);

-- Create a test batch / campaign
insert into public.message_batch (id, tenant_id, campus_id, title, channel)
values (gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, 'Annual Fee Campaign', 'sms');
select id as batch_id from public.message_batch where tenant_id = :'tenant_id'::uuid limit 1 \gset

-- Create message 1: for AC 1 (late 'sent' receipt after already 'delivered')
insert into public.message (
  id, tenant_id, campus_id, batch_id, recipient_phone, channel, body, status
) values (
  gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, :'batch_id'::uuid,
  '+923001112233', 'sms', 'Important Announcement', 'delivered'
);
select id as msg1_id from public.message where recipient_phone = '+923001112233' limit 1 \gset

insert into public.message_attempt (
  id, message_id, attempt_number, provider_ref, status, dispatched_at, completed_at, channel
) values (
  gen_random_uuid(), :'msg1_id'::uuid, 1, 'PROV-REF-DELIV-001', 'delivered', now() - interval '2 hours', now() - interval '1 hour', 'sms'
);
select id as att1_id from public.message_attempt where provider_ref = 'PROV-REF-DELIV-001' \gset

-- ─── 2. Test AC 1: Late 'sent' receipt arriving after 'delivered' ─────────
select public.apply_receipt(
  'telenor_sms',
  jsonb_build_object('provider_ref', 'PROV-REF-DELIV-001', 'status', 'sent', 'timestamp', now()::text),
  :'tenant_id'::uuid
);

-- State must remain 'delivered'
select is(
  (select status::text from public.message_attempt where id = :'att1_id'::uuid),
  'delivered',
  'AC 1: Attempt status remains delivered when late sent receipt arrives'
);

-- Receipt audit row must exist in message_receipt
select is(
  (select count(*)::int from public.message_receipt where message_attempt_id = :'att1_id'::uuid and status = 'sent'),
  1,
  'AC 1: Late receipt is saved in message_receipt audit table'
);

-- ─── 3. Test Monotonic Advancement (submitted -> sent -> delivered) ───────
insert into public.message (
  id, tenant_id, campus_id, batch_id, recipient_phone, channel, body, status
) values (
  gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, :'batch_id'::uuid,
  '+923004445566', 'sms', 'Grade Report Ready', 'sending'
);
select id as msg2_id from public.message where recipient_phone = '+923004445566' limit 1 \gset

insert into public.message_attempt (
  id, message_id, attempt_number, provider_ref, status, dispatched_at, channel
) values (
  gen_random_uuid(), :'msg2_id'::uuid, 1, 'PROV-REF-FLOW-002', 'sending', now() - interval '10 minutes', 'sms'
);
select id as att2_id from public.message_attempt where provider_ref = 'PROV-REF-FLOW-002' \gset

-- Step A: Advance to 'sent'
select public.apply_receipt(
  'jazz_sms',
  jsonb_build_object('provider_ref', 'PROV-REF-FLOW-002', 'status', 'sent'),
  :'tenant_id'::uuid
);

select is(
  (select status::text from public.message_attempt where id = :'att2_id'::uuid),
  'sent',
  'Attempt advances from sending to sent'
);

-- Step B: Advance to 'delivered'
select public.apply_receipt(
  'jazz_sms',
  jsonb_build_object('provider_ref', 'PROV-REF-FLOW-002', 'status', 'delivered'),
  :'tenant_id'::uuid
);

select is(
  (select status::text from public.message_attempt where id = :'att2_id'::uuid),
  'delivered',
  'Attempt advances from sent to delivered'
);

select is(
  (select status::text from public.message where id = :'msg2_id'::uuid),
  'delivered',
  'Parent message status advances to delivered'
);

-- ─── 4. Test AC 3: Dead-letter queue for non-matching provider_ref ─────────
select public.apply_receipt(
  'zong_sms',
  jsonb_build_object('provider_ref', 'UNKNOWN-ORPHAN-999', 'status', 'delivered', 'network', 'zong'),
  :'tenant_id'::uuid
);

-- Dead letter receipt must exist
select is(
  (select count(*)::int from public.dead_letter_receipt where provider_ref = 'UNKNOWN-ORPHAN-999'),
  1,
  'AC 3: Mismatched provider_ref written to dead_letter_receipt'
);

-- Retention must be 30 days
select ok(
  (select expires_at >= clock_timestamp() + interval '29 days'
   from public.dead_letter_receipt where provider_ref = 'UNKNOWN-ORPHAN-999'),
  'AC 3: Dead letter record retained for 30 days'
);

-- ─── 5. Test AC 4: Stale attempt sweeper (sent > 24 hours -> expired) ─────
insert into public.message (
  id, tenant_id, campus_id, batch_id, recipient_phone, channel, body, status
) values (
  gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, :'batch_id'::uuid,
  '+923007778899', 'sms', 'Old Notification', 'sent'
);
select id as msg3_id from public.message where recipient_phone = '+923007778899' limit 1 \gset

-- Dispatched 26 hours ago in 'sent' state
insert into public.message_attempt (
  id, message_id, attempt_number, provider_ref, status, dispatched_at, channel
) values (
  gen_random_uuid(), :'msg3_id'::uuid, 1, 'PROV-REF-STALE-003', 'sent', now() - interval '26 hours', 'sms'
);
select id as att3_id from public.message_attempt where provider_ref = 'PROV-REF-STALE-003' \gset

-- Another recent message (dispatched 2 hours ago in 'sent' state, should NOT expire)
insert into public.message (
  id, tenant_id, campus_id, batch_id, recipient_phone, channel, body, status
) values (
  gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, :'batch_id'::uuid,
  '+923000001122', 'sms', 'Recent Notification', 'sent'
);
select id as msg4_id from public.message where recipient_phone = '+923000001122' limit 1 \gset

insert into public.message_attempt (
  id, message_id, attempt_number, provider_ref, status, dispatched_at, channel
) values (
  gen_random_uuid(), :'msg4_id'::uuid, 1, 'PROV-REF-RECENT-004', 'sent', now() - interval '2 hours', 'sms'
);
select id as att4_id from public.message_attempt where provider_ref = 'PROV-REF-RECENT-004' \gset

-- Run sweeper
select public.expire_stale_attempts(:'tenant_id'::uuid, interval '24 hours');

-- Stale attempt must be 'expired'
select is(
  (select status::text from public.message_attempt where id = :'att3_id'::uuid),
  'expired',
  'AC 4: Attempt older than 24h transitioned to expired'
);

select is(
  (select status::text from public.message where id = :'msg3_id'::uuid),
  'expired',
  'AC 4: Parent message transitioned to expired (unreached)'
);

-- Recent attempt must still be 'sent'
select is(
  (select status::text from public.message_attempt where id = :'att4_id'::uuid),
  'sent',
  'AC 4: Recent attempt (under 24h) remains sent'
);

-- ─── 6. Test Delivery Stats View ───────────────────────────────────────────
select ok(
  (select count(*) > 0 from public.v_campaign_delivery_stats where tenant_id = :'tenant_id'::uuid),
  'Delivery stats view aggregates campaigns correctly'
);

select is(
  (select expired_count::int from public.v_campaign_delivery_stats where tenant_id = :'tenant_id'::uuid and campaign_id = :'batch_id'::uuid),
  1,
  'Delivery stats view reflects exactly 1 expired attempt'
);

rollback;
