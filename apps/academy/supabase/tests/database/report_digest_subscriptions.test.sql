-- pgTAP tests for FR-S05: scheduled report digest subscriptions.
begin;
select plan(34);

select public.provision_tenant('test-digest-co', 'Digest Co', 'owner@digest.test');
select id as tenant_id from public.tenant where slug = 'test-digest-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'DG2', 'Digest Campus Two') returning id as campus_b \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as nophone_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@digest.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@digest.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@digest.test', 'authenticated', 'authenticated', 'x'), (:'nophone_uid', 'n@digest.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name, phone_e164) values
  (:'owner_uid', :'tenant_id', 'owner', 'Digest Owner', '+923001112233'), (:'prin_uid', :'tenant_id', 'principal', 'Digest Principal', '+923004445566'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Digest Teacher', '+923007778899'), (:'nophone_uid', :'tenant_id', 'accountant', 'No Phone', null);
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'owner_uid', :'tenant_id', :'campus_a'), (:'prin_uid', :'tenant_id', :'campus_b'), (:'nophone_uid', :'tenant_id', :'campus_a');
-- aggregates exist for campus A only; the principal's campus B has nothing to report
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, collected_paisa, outstanding_paisa, outstanding_0_30_paisa)
values (:'tenant_id', :'campus_a', app.fn_karachi_today(), 1000, 900, 180000000, 90000000, 90000000);

-- today's 20:00, 21:00 and 22:00 Asia/Karachi as instants
select ((app.fn_karachi_today() + time '20:00') at time zone 'Asia/Karachi') as slot20, ((app.fn_karachi_today() + time '21:00') at time zone 'Asia/Karachi') as slot21,
       ((app.fn_karachi_today() + time '22:00') at time zone 'Asia/Karachi') as slot22 \gset

select has_table('public', 'report_subscription', 'report_subscription exists');
select has_table('public', 'report_delivery', 'report_delivery exists');
select has_index('public', 'report_delivery', 'uq_delivery_attempt', 'unique index uq_delivery_attempt exists');
select is((select count(*)::int from information_schema.columns where table_name = 'report_subscription' and column_name ~ 'cron|job'), 0, 'no per-subscription cron/job column: one dispatcher, not one cron entry per subscription');
select is(has_function_privilege('authenticated', 'public.dispatch_due_digests(timestamptz)', 'execute'), false, 'a client cannot run the dispatcher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'sms') as sub20 \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '21:00', 'sms') as sub21 \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '22:00', 'sms') as sub22 \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'in_app') as sub_app \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'email', 'Asia/Dubai') as sub_dubai \gset
select is((select timezone from public.report_subscription where id = :'sub20'), 'Asia/Karachi', 'the timezone defaults to Asia/Karachi');
select is((select run_at_local from public.report_subscription where id = :'sub20'), '20:00'::time, 'the run time is stored as local time, not UTC');
select is((select count(*)::int from public.report_subscription), 5, 'the owner sees their own five subscriptions');

select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'sms', 'Mars/Olympus') $$, 'TIMEZONE_INVALID', 'an unknown timezone is refused');
select throws_ok($$ select public.upsert_digest_subscription('no_such_report', 'daily', '20:00', 'sms') $$, 'REPORT_NOT_AVAILABLE', 'an unknown report is refused');

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'sms') $$, 'REPORT_NOT_AVAILABLE', 'a teacher cannot subscribe to a group summary');
select is((select count(*)::int from public.report_subscription), 0, 'RLS: report_subscription_self hides other users'' subscriptions');
select set_config('request.jwt.claims', json_build_object('sub', :'nophone_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'sms') $$, 'CHANNEL_CONTACT_MISSING', 'an SMS subscription needs a mobile number on file');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'sms') as sub_prin \gset
reset role;

-- ── AC1: sent within the 5-minute window of 20:00, delivery row records status and provider id ──
select is(public.dispatch_due_digests(:'slot20'::timestamptz - interval '5 minutes'), 0, 'nothing is dispatched before the slot (19:55)');
select is(public.dispatch_due_digests(:'slot20'::timestamptz + interval '2 minutes'), 3, 'AC1: at 20:02 the 20:00 subscriptions are dispatched (owner sms + in_app, principal)');
select is((select count(*)::int from public.report_delivery where subscription_id = :'sub20' and scheduled_for = :'slot20'::timestamptz and attempt_no = 1 and status = 'pending'), 1, 'AC1: a delivery row for the 20:00 slot exists');
select is(public.dispatch_due_digests(:'slot20'::timestamptz + interval '3 minutes'), 0, 'a second tick does not double-dispatch (uq_delivery_attempt)');
select is((select count(*)::int from public.report_delivery where subscription_id = :'sub_dubai'), 0, 'a Dubai 20:00 subscription is not due at Karachi 20:00');
select is((select payload -> 'variables' ->> 1 from public.report_delivery where subscription_id = :'sub20'), '1,800,000', 'the digest carries the figure in full, with separators');
select delivery_id as d20 from public.claim_digest_deliveries(10, :'slot20'::timestamptz + interval '2 minutes') where channel = 'sms' and to_msisdn = '+923001112233' \gset
select public.record_digest_attempt_result(:'d20'::uuid, true, 'sms-prov-77', null, false, :'slot20'::timestamptz + interval '3 minutes');
select is((select status || '/' || provider_msg_id from public.report_delivery where id = :'d20'::uuid), 'sent/sms-prov-77', 'AC1: the delivery row records status and the provider message id');
select ok((select delivered_at - scheduled_for <= interval '5 minutes' from public.report_delivery where id = :'d20'::uuid), 'AC1: delivered within 5 minutes of 20:00');
select is((select status from public.report_delivery where subscription_id = :'sub_app'), 'sent', 'an in_app subscription is delivered as a notification');

-- ── AC2: nothing to report -> skipped_empty and no message ────────────────
select is((select status from public.report_delivery where subscription_id = :'sub_prin'), 'skipped_empty', 'AC2: an empty report is recorded as skipped_empty');
select is((select count(*)::int from public.claim_digest_deliveries(50, :'slot20'::timestamptz + interval '30 minutes') where to_msisdn = '+923004445566'), 0, 'AC2: and nothing is queued for sending');

-- ── AC3: transient failure -> two retries at 5 and 25 minutes, final error visible ──
select public.dispatch_due_digests(:'slot21'::timestamptz + interval '1 minute');
select delivery_id as d21 from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '1 minute') where channel = 'sms' and to_msisdn = '+923001112233' \gset
select public.record_digest_attempt_result(:'d21'::uuid, false, null, 'HTTP 503 from SMS aggregator', true, :'slot21'::timestamptz + interval '1 minute');
select is((select next_attempt_at from public.report_delivery where subscription_id = :'sub21' and attempt_no = 2), :'slot21'::timestamptz + interval '5 minutes', 'AC3: the first retry is due 5 minutes after the slot');
select is((select count(*)::int from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '4 minutes') where channel = 'sms' and to_msisdn = '+923001112233'), 0, 'AC3: it is not claimable early');
select delivery_id as d21b from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '5 minutes') where channel = 'sms' and to_msisdn = '+923001112233' \gset
select public.record_digest_attempt_result(:'d21b'::uuid, false, null, 'HTTP 503 from SMS aggregator', true, :'slot21'::timestamptz + interval '5 minutes');
select is((select next_attempt_at from public.report_delivery where subscription_id = :'sub21' and attempt_no = 3), :'slot21'::timestamptz + interval '25 minutes', 'AC3: the second retry is due 25 minutes after the slot');
select delivery_id as d21c from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '25 minutes') where channel = 'sms' and to_msisdn = '+923001112233' \gset
select public.record_digest_attempt_result(:'d21c'::uuid, false, null, 'HTTP 503 from SMS aggregator', true, :'slot21'::timestamptz + interval '25 minutes');
select is((select count(*)::int from public.report_delivery where subscription_id = :'sub21'), 3, 'AC3: exactly two retries, no third');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select last_status || '|' || last_error from public.v_report_subscription_status where id = :'sub21'), 'failed|HTTP 503 from SMS aggregator', 'AC3: the subscription screen shows the final failure with the provider error text');

-- ── AC4: deactivated at 21:55 -> nothing at 22:00, no orphan ──────────────
select public.set_digest_subscription_active(:'sub22'::uuid, false);
reset role;
select is(public.dispatch_due_digests(:'slot22'::timestamptz + interval '1 minute'), 0, 'AC4: a subscription deactivated before 22:00 dispatches nothing');
select is((select count(*)::int from public.report_delivery where subscription_id = :'sub22'), 0, 'AC4: and leaves no delivery row behind');
update public.report_subscription set is_active = true where id = :'sub22';
select public.dispatch_due_digests(:'slot22'::timestamptz + interval '1 minute');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select public.set_digest_subscription_active(:'sub22'::uuid, false);
reset role;
select is((select status from public.report_delivery where subscription_id = :'sub22'), 'cancelled', 'AC4: deactivating cancels a pending attempt so nothing is sent');
select is((select count(*)::int from public.claim_digest_deliveries(50, :'slot22'::timestamptz + interval '1 hour') where to_msisdn = '+923001112233' and delivery_id in (select id from public.report_delivery where subscription_id = :'sub22')), 0, 'AC4: and it cannot be claimed');
delete from auth.users where id = :'owner_uid';
select is((select count(*)::int from public.report_subscription where user_id = :'owner_uid'), 0, 'deleting the user removes their subscriptions and deliveries: no orphaned schedule');

select * from finish();
rollback;
