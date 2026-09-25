-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M10: Message cost ledger and credit guard
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(12);

-- ─── 1. Setup Test Tenant & Fixtures ──────────────────────────────────────
select public.provision_tenant('test-comm-wallet', 'Wallet Guard Academy', 'owner@wallet.test');
select id as tenant_id from public.tenant where slug = 'test-comm-wallet' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

select gen_random_uuid() as owner_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_id', 'owner@wallet.test', 'x', now(), 'authenticated', 'authenticated');

insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_id', :'tenant_id', 'owner', 'Owner Officer');

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'owner_id',
    'email', 'owner@wallet.test',
    'app_metadata', json_build_object('role', 'authenticated')
  )::text,
  true
);

-- Initialize wallet with PKR 4,000 = 400,000 paisa
select public.top_up_comm_wallet(:'tenant_id'::uuid, 400000, 'Initial deposit');

select is(
  (select balance_paisa from public.tenant_comm_wallet where tenant_id = :'tenant_id'::uuid),
  400000::bigint,
  'Prepaid wallet successfully initialized with 400,000 paisa (PKR 4,000)'
);

-- ─── 2. Test AC 1: 3-Segment Urdu SMS at PKR 1.20 (120 paisa) ────────────
-- 3-segment Urdu message body (40 repetitions of 'سلام ' = 3 ucs2 segments)
insert into public.message (
  id, tenant_id, campus_id, recipient_phone, channel, body, status
) values (
  gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, '+923001112233', 'sms',
  repeat('سلام ', 40),
  'delivered'
);
select id as urdu_msg_id from public.message where recipient_phone = '+923001112233' and tenant_id = :'tenant_id'::uuid limit 1 \gset

insert into public.message_attempt (
  id, message_id, attempt_number, provider_ref, status, channel
) values (
  gen_random_uuid(), :'urdu_msg_id'::uuid, 1, 'URDU-SMS-ATT-01', 'delivered', 'sms'
);
select id as urdu_att_id from public.message_attempt where provider_ref = 'URDU-SMS-ATT-01' \gset

-- Record attempt cost
select public.record_attempt_cost(:'urdu_att_id'::uuid);

-- Verify ledger row has 360 paisa (3 segments * 120 paisa)
select is(
  (select cost_paisa from public.message_cost_ledger where attempt_id = :'urdu_att_id'::uuid),
  360,
  'AC 1: 3-segment Urdu SMS at PKR 1.20 creates ledger row of 360 paisa'
);

select ok(
  (select rate_card_id is not null from public.message_cost_ledger where attempt_id = :'urdu_att_id'::uuid),
  'AC 1: Cost ledger references effective-dated rate card id'
);

-- Verify wallet was debited by 360 paisa
select is(
  (select balance_paisa from public.tenant_comm_wallet where tenant_id = :'tenant_id'::uuid),
  (400000 - 360)::bigint,
  'Wallet balance was debited by exactly 360 paisa'
);

-- ─── 3. Test AC 2: WhatsApp Utility Conversation (6 messages = 1 cost row) ───
-- Create 6 messages in the same conversation
insert into public.message (id, tenant_id, campus_id, recipient_phone, channel, body, status)
select gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, '+923002223344', 'whatsapp', 'WhatsApp Msg ' || i, 'delivered'
from generate_series(1, 6) as i;

insert into public.message_attempt (id, message_id, attempt_number, provider_ref, status, channel)
select gen_random_uuid(), m.id, 1, 'WA-ATT-' || row_number() over (), 'delivered', 'whatsapp'
from public.message m
where m.tenant_id = :'tenant_id'::uuid and m.recipient_phone = '+923002223344';

-- Record attempt cost for each message with same conversation_id
select public.record_attempt_cost(ma.id, 'all', 'WA-CONV-SESSION-2026')
from public.message_attempt ma
join public.message m on m.id = ma.message_id
where m.tenant_id = :'tenant_id'::uuid and m.recipient_phone = '+923002223344';

-- Verify exactly ONE ledger cost row exists for the conversation
select is(
  (select count(*)::int from public.message_cost_ledger where conversation_id = 'WA-CONV-SESSION-2026'),
  1,
  'AC 2: Exactly ONE conversation-level cost row exists for 6 WhatsApp messages'
);

select is(
  (select cost_paisa from public.message_cost_ledger where conversation_id = 'WA-CONV-SESSION-2026'),
  250,
  'AC 2: Conversation cost recorded as 250 paisa (PKR 2.50)'
);

-- ─── 4. Test AC 3: Credit Guard Rejection with Shortfall ───────────────────
-- Reset balance back to exactly PKR 4,000 = 400,000 paisa
update public.tenant_comm_wallet
set balance_paisa = 400000
where tenant_id = :'tenant_id'::uuid;

-- Create campaign of 5,000 1-segment Urdu SMS (5,000 * 120 paisa = 600,000 paisa = PKR 6,000)
insert into public.message_batch (id, tenant_id, campus_id, title, channel)
values (gen_random_uuid(), :'tenant_id'::uuid, :'campus_id'::uuid, 'Mass Fee Reminder', 'sms');
select id as batch6k_id from public.message_batch where title = 'Mass Fee Reminder' and tenant_id = :'tenant_id'::uuid limit 1 \gset

-- Insert messages that total 600,000 paisa (5,000 messages * 1 segment * 120 paisa)
insert into public.message (tenant_id, campus_id, batch_id, recipient_phone, channel, body, status)
select :'tenant_id'::uuid, :'campus_id'::uuid, :'batch6k_id'::uuid, '+92300555' || lpad(i::text, 4, '0'), 'sms',
       'فیس واؤچر', 'queued'
from generate_series(1, 5000) as i;

-- Estimate cost should be 600,000 paisa (PKR 6,000)
select is(
  (select public.estimate_campaign_cost(:'batch6k_id'::uuid)),
  600000::bigint,
  'AC 3: Campaign estimated cost is 600,000 paisa (PKR 6,000)'
);

-- Expect guard_campaign_dispatch to raise exception showing exactly PKR 2,000 shortfall
select throws_matching(
  'select public.guard_campaign_dispatch(''' || :'batch6k_id' || '''::uuid)',
  'INSUFFICIENT_COMM_BALANCE.*Shortfall: PKR 2,000\.00',
  'AC 3: Dispatch rejected when balance < estimated cost, showing exact shortfall of PKR 2,000'
);

-- ─── 5. Test AC 4: Strict Concurrency / Balance Never Goes Negative ───────
-- First debit of PKR 3,000 (300,000 paisa) against PKR 4,000 balance succeeds
select lives_ok(
  'select public.debit_comm_wallet(''' || :'tenant_id' || '''::uuid, 300000, ''Campaign A'');',
  'AC 4: First campaign of PKR 3,000 evaluates and succeeds'
);

select is(
  (select balance_paisa from public.tenant_comm_wallet where tenant_id = :'tenant_id'::uuid),
  100000::bigint,
  'AC 4: Remaining wallet balance is 100,000 paisa (PKR 1,000)'
);

-- Second debit of PKR 3,000 (300,000 paisa) fails because 100,000 < 300,000
select throws_matching(
  'select public.debit_comm_wallet(''' || :'tenant_id' || '''::uuid, 300000, ''Campaign B'');',
  'INSUFFICIENT_COMM_BALANCE',
  'AC 4: Second concurrent campaign fails and balance is preserved without going negative'
);

select is(
  (select balance_paisa from public.tenant_comm_wallet where tenant_id = :'tenant_id'::uuid),
  100000::bigint,
  'AC 4: Balance never goes negative'
);

rollback;
