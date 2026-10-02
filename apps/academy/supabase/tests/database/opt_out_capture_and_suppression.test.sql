-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M11: Opt-out capture and suppression
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(12);

-- ─── 1. Setup Test Tenant & Fixtures ──────────────────────────────────────
select public.provision_tenant('test-comm-optout', 'OptOut Guard Academy', 'owner@optout.test');
select id as tenant_id from public.tenant where slug = 'test-comm-optout' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

select gen_random_uuid() as admin_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_id', 'owner@optout.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_id', :'tenant_id', 'owner', 'Owner Officer');

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'admin_id',
    'email', 'owner@optout.test',
    'app_metadata', json_build_object('role', 'authenticated')
  )::text,
  true
);

-- ─── 2. Test AC 1: Inbound SMS with 'STOP' or 'بند' ───────────────────────
-- Test 1A: English STOP
insert into public.inbound_sms (tenant_id, from_phone, to_mask, body)
values (:'tenant_id'::uuid, '+923001112233', 'SEENA', 'STOP');

-- Verify suppression row created automatically by trigger
select is(
  (select count(*)::int from public.comm_opt_out 
   where tenant_id = :'tenant_id'::uuid and recipient_phone = '+923001112233' and channel = 'sms'),
  1,
  'AC 1: Inbound English STOP creates suppression row automatically'
);

-- Test 1B: Urdu بند keyword
insert into public.inbound_sms (tenant_id, from_phone, to_mask, body)
values (:'tenant_id'::uuid, '+923004445566', 'SEENA', 'بند');

select is(
  (select count(*)::int from public.comm_opt_out 
   where tenant_id = :'tenant_id'::uuid and recipient_phone = '+923004445566' and channel = 'sms'),
  1,
  'AC 1: Inbound Urdu بند keyword creates suppression row automatically'
);

-- Test 1C: Next non-exempt campaign skips opted-out recipient with reason 'opted_out'
insert into public.message_batch (id, tenant_id, campus_id, title, channel)
values (gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, 'Spring Carnival Promo', 'sms');
select id as promo_batch_id from public.message_batch where title = 'Spring Carnival Promo' and tenant_id = :'tenant_id'::uuid limit 1 \gset

insert into public.message (
  tenant_id, campus_id, batch_id, recipient_phone, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'promo_batch_id'::uuid, '+923001112233', 'sms',
  'Come to the Spring Carnival!', 'queued', 'marketing'
);
select id as promo_msg_id from public.message where batch_id = :'promo_batch_id'::uuid limit 1 \gset

-- Apply dispatch suppression
select public.apply_dispatch_suppression(:'promo_batch_id'::uuid);

select is(
  (select status::text from public.message where id = :'promo_msg_id'::uuid),
  'cancelled',
  'AC 1: Non-exempt marketing message is skipped for opted-out recipient'
);

select is(
  (select metadata->>'skip_reason' from public.message where id = :'promo_msg_id'::uuid),
  'opted_out',
  'AC 1: Message metadata records skip_reason = opted_out'
);

-- ─── 3. Test AC 2: Transactional Exemption ────────────────────────────────
-- Create a fee-challan message classed as transactional for the SAME opted-out parent (+923001112233)
insert into public.message_batch (id, tenant_id, campus_id, title, channel)
values (gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, 'Monthly Fee Challans', 'sms');
select id as fee_batch_id from public.message_batch where title = 'Monthly Fee Challans' and tenant_id = :'tenant_id'::uuid limit 1 \gset

insert into public.message (
  tenant_id, campus_id, batch_id, recipient_phone, channel, body, status, message_class
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, :'fee_batch_id'::uuid, '+923001112233', 'sms',
  'Dear Parent, Fee Challan for March is ready. Due date: 10th.', 'queued', 'transactional'
);
select id as fee_msg_id from public.message where batch_id = :'fee_batch_id'::uuid limit 1 \gset

-- Verify is_suppressed is FALSE for transactional class
select is(
  public.is_suppressed(:'tenant_id'::uuid, '+923001112233', 'sms', 'transactional'),
  false,
  'AC 2: is_suppressed returns false for transactional message_class'
);

-- Apply dispatch suppression: fee message must NOT be skipped
select public.apply_dispatch_suppression(:'fee_batch_id'::uuid);

select is(
  (select status::text from public.message where id = :'fee_msg_id'::uuid),
  'queued',
  'AC 2: Transactional fee message remains queued for dispatch despite parent opt-out'
);

-- ─── 4. Test AC 3: Portal Re-subscription & Audit Trail ───────────────────
-- Re-subscribe +923001112233 via portal
select public.resubscribe_recipient(
  :'tenant_id'::uuid,
  '+923001112233',
  'sms',
  :'admin_id'::uuid,
  'Parent re-enabled notifications in parent portal'
);

-- Verify suppression row is gone
select is(
  (select count(*)::int from public.comm_opt_out 
   where tenant_id = :'tenant_id'::uuid and recipient_phone = '+923001112233' and channel = 'sms'),
  0,
  'AC 3: Suppression row is deleted when parent re-subscribes'
);

-- Verify audit row is recorded with actor_id and timestamp
select is(
  (select count(*)::int from public.comm_opt_out_audit 
   where tenant_id = :'tenant_id'::uuid and recipient_phone = '+923001112233' and action = 'resubscribe'),
  1,
  'AC 3: Audit row exists for resubscription action'
);

select is(
  (select actor_id from public.comm_opt_out_audit 
   where tenant_id = :'tenant_id'::uuid and recipient_phone = '+923001112233' and action = 'resubscribe' limit 1),
  :'admin_id'::uuid,
  'AC 3: Audit row records actor_id'
);

-- ─── 5. Test AC 4: Campaign Preview for 640 total with 37 suppressed ─────
-- Seed a test batch with 640 recipients
insert into public.message_batch (id, tenant_id, campus_id, title, channel)
values (gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, 'Annual Sports Gala', 'sms');
select id as sports_batch_id from public.message_batch where title = 'Annual Sports Gala' and tenant_id = :'tenant_id'::uuid limit 1 \gset

-- 37 suppressed recipients (+923009990001 to +923009990037)
insert into public.comm_opt_out (tenant_id, recipient_phone, channel, reason, source)
select :'tenant_id'::uuid, '+92300999' || lpad(i::text, 4, '0'), 'sms', 'Opted out', 'user_request'
from generate_series(1, 37) as i;

-- Insert 640 marketing messages (37 suppressed, 603 sendable)
insert into public.message (tenant_id, campus_id, batch_id, recipient_phone, channel, body, status, message_class)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'sports_batch_id'::uuid,
       '+92300999' || lpad(i::text, 4, '0'), 'sms', 'Sports Day Gala Invitation', 'queued', 'marketing'
from generate_series(1, 640) as i;

-- Run preview_campaign_suppression
select is(
  (select (public.preview_campaign_suppression(:'sports_batch_id'::uuid))->>'total'),
  '640',
  'AC 4: Preview shows total 640 recipients'
);

select is(
  (select (public.preview_campaign_suppression(:'sports_batch_id'::uuid))->>'suppressed'),
  '37',
  'AC 4: Preview shows 37 suppressed recipients'
);

select is(
  (select (public.preview_campaign_suppression(:'sports_batch_id'::uuid))->>'sendable'),
  '603',
  'AC 4: Preview shows 603 sendable recipients'
);

rollback;
