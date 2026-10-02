-- pgTAP tests for FR-M01: Unified outbound message outbox
begin;
select plan(22);

-- 1. Setup tenant, campuses, and test fixtures
select public.provision_tenant('test-msg-outbox', 'Message Outbox Academy', 'owner@msgoutbox.test');
select id as tenant_id from public.tenant where slug = 'test-msg-outbox' \gset
select id as campus_1_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

-- Create a second campus for tenant to test cross-campus scoping
insert into public.campus (tenant_id, code, name)
values (:'tenant_id'::uuid, 'CAMPUS-2', 'Second Campus')
returning id as campus_2_id \gset

select id as jazz_provider_id from public.comm_provider where code = 'jazz_sms' \gset

-- 2. Schema integrity tests
select has_table('public', 'comm_provider', 'comm_provider table exists');
select has_table('public', 'comm_provider_credential', 'comm_provider_credential table exists');
select has_table('public', 'message_batch', 'message_batch table exists');
select has_table('public', 'message', 'message table exists');
select has_table('public', 'message_attempt', 'message_attempt table exists');

select has_function('public', 'claim_message_batch', array['uuid', 'integer', 'uuid', 'public.comm_channel'], 'claim_message_batch function exists');
select has_function('public', 'record_message_attempt', array['uuid', 'uuid', 'public.attempt_status', 'text', 'text', 'text', 'jsonb'], 'record_message_attempt function exists');
select has_function('public', 'resolve_unknown_attempt', array['uuid', 'public.attempt_status', 'text', 'jsonb'], 'resolve_unknown_attempt function exists');

-- 3. AC 3: RLS Campus Scoping (SQLSTATE 42501 on unauthorized campus insert)
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'principal',
    'campus_ids', json_build_array(:'campus_1_id')
  )::text,
  true
);

-- Insert for authorized campus_1 succeeds
insert into public.message (
  tenant_id,
  campus_id,
  recipient_phone,
  channel,
  body,
  idempotency_key
) values (
  :'tenant_id'::uuid,
  :'campus_1_id'::uuid,
  '+923001112233',
  'sms',
  'Dear Parent, School will remain closed tomorrow.',
  'msg-idem-test-1'
) returning id as msg_1_id \gset

select isnt_empty(
  'select id from public.message where idempotency_key = ''msg-idem-test-1''',
  'Authorized campus insert succeeds under RLS'
);

-- AC 3 Test: Insert for campus_2 (not in user claims) throws 42501
select throws_ok(
  format(
    'insert into public.message (tenant_id, campus_id, recipient_phone, channel, body) values (''%s'', ''%s'', ''+923009998877'', ''sms'', ''Unauthorized broadcast'')',
    :'tenant_id',
    :'campus_2_id'
  ),
  '42501',
  null,
  'AC 3: Inserting message with non-permitted campus_id is rejected by RLS with SQLSTATE 42501'
);

-- 4. AC 2: Crash recovery & Idempotency Key protection
-- Attempting duplicate insert with same (tenant_id, idempotency_key) is rejected by unique index
select throws_matching(
  format(
    'insert into public.message (tenant_id, campus_id, recipient_phone, channel, body, idempotency_key) values (''%s'', ''%s'', ''+923001112233'', ''sms'', ''Duplicate body'', ''msg-idem-test-1'')',
    :'tenant_id',
    :'campus_1_id'
  ),
  'duplicate key value violates unique constraint "idx_message_idempotency"',
  'AC 2: Duplicate insertion with same idempotency key is rejected'
);

-- Existing message can be retrieved via idempotency key
select results_eq(
  'select id from public.message where tenant_id = ''' || :'tenant_id' || ''' and idempotency_key = ''msg-idem-test-1''',
  'select ''' || :'msg_1_id' || '''::uuid',
  'AC 2: Stored idempotency key enables retrieval of existing message row'
);

-- 5. AC 1: Concurrency & Disjoint Queue Batch Claims (SKIP LOCKED)
reset role;

-- Populate multiple queued messages
insert into public.message (tenant_id, campus_id, recipient_phone, channel, body, idempotency_key)
values
  (:'tenant_id'::uuid, :'campus_1_id'::uuid, '+923001000001', 'sms', 'Queue Test 1', 'q-1'),
  (:'tenant_id'::uuid, :'campus_1_id'::uuid, '+923001000002', 'sms', 'Queue Test 2', 'q-2'),
  (:'tenant_id'::uuid, :'campus_1_id'::uuid, '+923001000003', 'sms', 'Queue Test 3', 'q-3'),
  (:'tenant_id'::uuid, :'campus_1_id'::uuid, '+923001000004', 'sms', 'Queue Test 4', 'q-4');

select gen_random_uuid() as worker_1 \gset
select gen_random_uuid() as worker_2 \gset

-- Worker 1 claims 2 messages
create temp table w1_claimed as
select id from public.claim_message_batch(:'worker_1'::uuid, 2, :'tenant_id'::uuid, 'sms'::public.comm_channel);

-- Worker 2 concurrently claims next batch
create temp table w2_claimed as
select id from public.claim_message_batch(:'worker_2'::uuid, 2, :'tenant_id'::uuid, 'sms'::public.comm_channel);

select results_eq(
  'select count(*)::int from w1_claimed',
  'select 2',
  'Worker 1 successfully claimed 2 messages'
);

select results_eq(
  'select count(*)::int from w2_claimed',
  'select 2',
  'Worker 2 successfully claimed 2 messages'
);

-- Verify that w1 and w2 sets are completely disjoint (AC 1: no duplicates)
select is_empty(
  'select id from w1_claimed intersect select id from w2_claimed',
  'AC 1: Multiple concurrent dispatch workers claim mutually exclusive messages (no duplicates)'
);

-- Verify status in main table is now 'claimed'
select results_eq(
  'select count(*)::int from public.message where status = ''claimed'' and tenant_id = ''' || :'tenant_id' || '''',
  'select 4',
  'All 4 claimed messages have status = claimed'
);

-- 6. Attempt Recording & AC 4: Pakistani SMS Aggregator Timeout & Unknown Status Resolution
select id as first_claimed_id from w1_claimed limit 1 \gset

-- Dispatcher records attempt: provider times out after 30s
select public.record_message_attempt(
  :'first_claimed_id'::uuid,
  :'jazz_provider_id'::uuid,
  'timeout'::public.attempt_status,
  null,
  'GATEWAY_TIMEOUT_504',
  'Aggregator HTTP 504 Gateway Timeout after 30s'
) as attempt_row \gset

-- Verify message status is 'unknown' (never blindly retried)
select results_eq(
  'select status::text from public.message where id = ''' || :'first_claimed_id' || '''',
  'select ''unknown''',
  'AC 4: Timed out attempt marks message status as unknown rather than blind retry'
);

select id as timeout_attempt_id from public.message_attempt where message_id = :'first_claimed_id'::uuid \gset

-- Now resolve by provider status lookup (e.g. status enquiry background task)
select public.resolve_unknown_attempt(
  :'timeout_attempt_id'::uuid,
  'delivered'::public.attempt_status,
  'JAZZ-DLR-TX-883921',
  '{"provider_status": "DELIVRD", "network": "Jazz", "price_paisa": 120}'::jsonb
);

-- Verify attempt and message are resolved to delivered
select results_eq(
  'select status::text from public.message_attempt where id = ''' || :'timeout_attempt_id' || '''',
  'select ''delivered''',
  'AC 4: Attempt resolved to delivered via provider reference lookup'
);

select results_eq(
  'select status::text from public.message where id = ''' || :'first_claimed_id' || '''',
  'select ''delivered''',
  'AC 4: Parent message status updated to delivered without generating duplicate SMS'
);

select results_eq(
  'select provider_ref from public.message_attempt where id = ''' || :'timeout_attempt_id' || '''',
  'select ''JAZZ-DLR-TX-883921''',
  'Provider reference captured on attempt record'
);

-- 7. Credentials Isolation: Non-owner / Non-admin cannot read credentials
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'teacher',
    'campus_ids', json_build_array(:'campus_1_id')
  )::text,
  true
);

select is_empty(
  'select * from public.comm_provider_credential where tenant_id = ''' || :'tenant_id' || '''',
  'Teacher role cannot read comm_provider_credential rows'
);

-- Owner can read credentials
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_1_id')
  )::text,
  true
);

insert into public.comm_provider_credential (
  tenant_id,
  provider_id,
  credential_vault_ref,
  sender_id
) values (
  :'tenant_id'::uuid,
  :'jazz_provider_id'::uuid,
  'vault://secrets/jazz_sms_api_key',
  'SEENA'
);

select isnt_empty(
  'select * from public.comm_provider_credential where tenant_id = ''' || :'tenant_id' || '''',
  'Owner role can access comm_provider_credential'
);

-- Clean finish
rollback;
