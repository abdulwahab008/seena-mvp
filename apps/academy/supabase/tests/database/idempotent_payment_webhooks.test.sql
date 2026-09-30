-- pgTAP tests for FR-K22: idempotent, signature-verified payment webhooks.
begin;
select plan(28);

select public.provision_tenant('test-webhook-co', 'Webhook Co', 'owner@webhookco.test');
select id as tenant_id from public.tenant where slug = 'test-webhook-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-webhook-other', 'Other Webhook Co', 'owner@otherwebhookco.test');
select id as other_tenant_id from public.tenant where slug = 'test-webhook-other' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Hook Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Hook Kid Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.create_student(:'campus_id'::uuid, 'Hook Kid Three', '2015-03-01'::date, 'male') as s3 \gset
select public.enrol_student(:'section_id'::uuid, :'s3'::uuid) as e3 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.upsert_payment_gateway_config('jazzcash', 'MC-HOOK-1', 'PAY_SECRET_JAZZCASH');
reset role;

select id as ch1 from public.fee_challan where enrolment_id = :'e1' \gset
select id as ch2 from public.fee_challan where enrolment_id = :'e2' \gset
select id as ch3 from public.fee_challan where enrolment_id = :'e3' \gset

-- three intents, made the way the portal makes them
insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at)
select :'tenant_id', :'campus_id', e, c, 'jazzcash', r, 500000, now() + interval '30 minutes'
  from (values (:'e1'::uuid, :'ch1'::uuid, 'JA-REF-ONE'), (:'e2'::uuid, :'ch2'::uuid, 'JA-REF-TWO'), (:'e3'::uuid, :'ch3'::uuid, 'JA-REF-THREE')) v(e, c, r);

select has_table('public', 'payment_webhook_event', 'payment_webhook_event exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.payment_webhook_event'::regclass, 'public.payment_alert'::regclass)), 'RLS on the event and alert tables');
select is(has_function_privilege('anon', 'public.ingest_payment_webhook(text,text,jsonb,text,boolean)', 'execute'), false, 'anon cannot ingest');
select is(has_function_privilege('authenticated', 'public.ingest_payment_webhook(text,text,jsonb,text,boolean)', 'execute'), false, 'authenticated cannot ingest');
select is(has_function_privilege('service_role', 'public.ingest_payment_webhook(text,text,jsonb,text,boolean)', 'execute'), true, 'service_role can ingest');

-- ── exactly-once ──────────────────────────────────────────────────────────

set local role service_role;
select public.ingest_payment_webhook('jazzcash', 'T-9001', '{"gateway_ref":"JA-REF-ONE","status":"success","amount_paisa":500000}'::jsonb, '{"t":1}', true) as r1 \gset
select public.ingest_payment_webhook('jazzcash', 'T-9001', '{"gateway_ref":"JA-REF-ONE","status":"success","amount_paisa":500000}'::jsonb, '{"t":1}', true) as r2 \gset
select public.ingest_payment_webhook('jazzcash', 'T-9001', '{"gateway_ref":"JA-REF-ONE","status":"success","amount_paisa":500000}'::jsonb, '{"t":1}', true) as r3 \gset
select public.ingest_payment_webhook('jazzcash', 'T-9001', '{"gateway_ref":"JA-REF-ONE","status":"success","amount_paisa":500000}'::jsonb, '{"t":1}', true) as r4 \gset
reset role;
select is((:'r1'::jsonb ->> 'result'), 'processed', 'the first valid callback is processed');
select is(array[(:'r2'::jsonb ->> 'result'), (:'r3'::jsonb ->> 'result'), (:'r4'::jsonb ->> 'result')], array['duplicate', 'duplicate', 'duplicate'], 'AC: callbacks 2-4 are duplicates');
select is((select count(*)::int from public.fee_payment where tenant_id = :'tenant_id' and reference_no = 'T-9001'), 1, 'AC: exactly one payment exists');
select is((select count(*)::int from public.fee_ledger where enrolment_id = :'e1' and direction = 'credit' and source_type = 'fee_payment'), 1, 'AC: exactly one ledger credit exists');
select is((select status::text from public.fee_challan where id = :'ch1'), 'paid', 'the challan is paid');
select is((select status from public.payment_intent where gateway_ref = 'JA-REF-ONE'), 'succeeded', 'the intent succeeded');

-- ── signature failures store the raw body and post nothing ────────────────

set local role service_role;
select public.ingest_payment_webhook('jazzcash', 'T-9002', '{"gateway_ref":"JA-REF-TWO","status":"success","amount_paisa":500000}'::jsonb, 'FORGED-BODY', false) as r_bad \gset
reset role;
select is((:'r_bad'::jsonb ->> 'result'), 'signature_invalid', 'AC: a bad signature is rejected');
select is((select count(*)::int from public.payment_webhook_event where status = 'signature_invalid' and raw_body = 'FORGED-BODY'), 1, 'AC: the raw body is stored');
select is((select count(*)::int from public.fee_payment where reference_no = 'T-9002'), 0, 'AC: no payment is posted');

set local role service_role;
select public.ingest_payment_webhook('jazzcash', 'T-9002', '{"gateway_ref":"JA-REF-TWO","status":"success","amount_paisa":400000}'::jsonb, '{"t":2}', true) as r_short \gset
reset role;
select is((:'r_short'::jsonb ->> 'result'), 'processed', 'a forged event did not squat the real transaction id');

-- ── amount mismatch: partial payment + alert, not "paid" ──────────────────

select is((select status::text from public.fee_challan where id = :'ch2'), 'part_paid', 'AC: an 4,000 callback against 5,000 leaves the challan part-paid');
select is((select amount_paisa from public.fee_payment where reference_no = 'T-9002'), 400000::bigint, 'the amount actually received is what posts');
select is((select count(*)::int from public.payment_alert where tenant_id = :'tenant_id' and kind = 'amount_mismatch' and expected_paisa = 500000 and received_paisa = 400000), 1, 'AC: an amount_mismatch alert is raised');

-- ── orphan: callback before the intent is visible ─────────────────────────

set local role service_role;
select public.ingest_payment_webhook('jazzcash', 'T-9003', '{"gateway_ref":"JA-LATE-REF","status":"success","amount_paisa":500000}'::jsonb, '{"t":3}', true) as r_orphan \gset
reset role;
select is((:'r_orphan'::jsonb ->> 'result'), 'orphan', 'AC: a callback with no intent yet is kept as an orphan');
update public.payment_intent set gateway_ref = 'JA-LATE-REF' where gateway_ref = 'JA-REF-THREE';
set local role service_role;
select is(public.retry_orphan_webhooks(), 1, 'AC: the retry job reprocesses it once the intent is visible');
reset role;
select is((select status::text from public.fee_challan where id = :'ch3'), 'paid', 'AC: after which the payment posts');
select is((select status from public.payment_webhook_event where gateway_txn_id = 'T-9003'), 'processed', 'the orphan event is now processed');

-- ── failed payments and late successes ────────────────────────────────────

insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at, status)
values (:'tenant_id', :'campus_id', :'e2', :'ch2', 'jazzcash', 'JA-REF-FAIL', 100000, now() + interval '30 minutes', 'initiated'),
       (:'tenant_id', :'campus_id', :'e2', :'ch2', 'jazzcash', 'JA-REF-LATE', 100000, now() - interval '5 minutes', 'expired');
set local role service_role;
select public.ingest_payment_webhook('jazzcash', 'T-9004', '{"gateway_ref":"JA-REF-FAIL","status":"failed"}'::jsonb, '{"t":4}', true);
select public.ingest_payment_webhook('jazzcash', 'T-9005', '{"gateway_ref":"JA-REF-LATE","status":"success","amount_paisa":100000}'::jsonb, '{"t":5}', true);
reset role;
select is((select status from public.payment_intent where gateway_ref = 'JA-REF-FAIL'), 'failed', 'a failed callback fails the intent');
select is((select count(*)::int from public.fee_payment where reference_no = 'T-9004'), 0, 'and posts no payment');
select is((select count(*)::int from public.payment_alert where tenant_id = :'tenant_id' and kind = 'late_success'), 1, 'a success after expiry still posts, with a late_success alert');

-- ── RLS ───────────────────────────────────────────────────────────────────

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.payment_webhook_event), 0, 'no client role can read raw webhook events — not even the owner');
select is((select count(*)::int from public.payment_alert) >= 2, true, 'finance staff see the alerts');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.payment_alert), 0, 'another school sees none');
reset role;

select * from finish();
rollback;
