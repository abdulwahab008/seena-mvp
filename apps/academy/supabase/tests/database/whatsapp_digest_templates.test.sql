-- pgTAP tests for FR-S06: WhatsApp digest template delivery.
begin;
select plan(31);

select public.provision_tenant('test-wadigest-co', 'WA Digest Co', 'owner@wadigest.test');
select id as tenant_id from public.tenant where slug = 'test-wadigest-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-wadigest-other', 'Other WA Co', 'owner@otherwadigest.test');
select id as other_tenant_id from public.tenant where slug = 'test-wadigest-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@wadigest.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@wadigest.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name, phone_e164) values
  (:'owner_uid', :'tenant_id', 'owner', 'WA Owner', '+923001112233'), (:'prin_uid', :'tenant_id', 'principal', 'WA Principal', '+923004445566');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'owner_uid', :'tenant_id', :'campus_a'), (:'prin_uid', :'tenant_id', :'campus_a');
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, collected_paisa, outstanding_paisa, outstanding_0_30_paisa)
values (:'tenant_id', :'campus_a', app.fn_karachi_today(), 1000, 900, 180000000, 90000000, 90000000);
select ((app.fn_karachi_today() + time '20:00') at time zone 'Asia/Karachi') as slot20, ((app.fn_karachi_today() + time '21:00') at time zone 'Asia/Karachi') as slot21,
       ((app.fn_karachi_today() + time '22:00') at time zone 'Asia/Karachi') as slot22, ((app.fn_karachi_today() + time '23:00') at time zone 'Asia/Karachi') as slot23 \gset

-- the school registers its approved template (service role, as the platform does at onboarding)
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.seed_digest_wa_templates(:'tenant_id'::uuid);
select set_config('request.jwt.claims', '', true);

select has_column('public', 'wa_template', 'variable_count', 'wa_template declares its variable count');
select is((select variable_count from public.wa_template where tenant_id = :'tenant_id' and meta_template_name = 'daily_summary_v1'), 5, 'AC1: the approved template daily_summary_v1 declares 5 variables');
select is((select status::text from public.wa_template where tenant_id = :'tenant_id' and meta_template_name = 'daily_summary_v1'), 'APPROVED', 'and it is approved');
select is(has_function_privilege('authenticated', 'public.digest_provider_secret(text)', 'execute'), false, 'the WABA token reader is not callable from a client');
select is(has_function_privilege('service_role', 'public.digest_provider_secret(text)', 'execute'), true, 'it is available to the server worker (Vault read)');

-- ── AC4: rejected at save time, naming the missing template ───────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'whatsapp', 'Asia/Karachi', '{}', 'ur') $$, '22023', 'WA_TEMPLATE_MISSING: daily_summary_v1 (ur)', 'AC4: no Urdu template -> rejected at save, naming daily_summary_v1 (ur)');
select is((select count(*)::int from public.report_subscription), 0, 'AC4: nothing was saved');
reset role;
insert into public.wa_template (tenant_id, meta_template_name, category, status, language, body_text, report_key, variable_count)
values (:'tenant_id', 'daily_summary_v1', 'UTILITY', 'PENDING', 'ur', 'x {{1}}', 'group_daily_summary', 5);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'whatsapp', 'Asia/Karachi', '{}', 'ur') $$, '22023', 'WA_TEMPLATE_MISSING: daily_summary_v1 (ur)', 'AC4: a template that is only PENDING does not count');
reset role;
update public.wa_template set status = 'APPROVED', variable_count = 4 where tenant_id = :'tenant_id' and language = 'ur';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'whatsapp', 'Asia/Karachi', '{}', 'ur') $$, '22023', 'WA_TEMPLATE_MISSING: daily_summary_v1 (ur)', 'AC4: nor does one declaring the wrong number of variables');
reset role;
update public.wa_template set variable_count = 5 where tenant_id = :'tenant_id' and language = 'ur';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select lives_ok($$ select public.upsert_digest_subscription('group_daily_summary', 'daily', '23:00', 'whatsapp', 'Asia/Karachi', '{}', 'ur') $$, 'once an approved 5-variable Urdu template exists the Urdu subscription saves');
select public.upsert_digest_subscription('group_daily_summary', 'daily', '20:00', 'whatsapp') as sub_wa \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '21:00', 'whatsapp') as sub_wa_fb \gset
select public.upsert_digest_subscription('group_daily_summary', 'daily', '22:00', 'whatsapp') as sub_wa_retry \gset
reset role;

-- ── AC1: a template message with exactly 5 variables, never free-form ────
select public.dispatch_due_digests(:'slot20'::timestamptz + interval '1 minute');
select * from public.claim_digest_deliveries(10, :'slot20'::timestamptz + interval '1 minute') where channel = 'whatsapp' \gset wa_
select is(:'wa_template_name'::text, 'daily_summary_v1', 'AC1: it is sent as a template message');
select is(jsonb_array_length(:'wa_variables'::jsonb), 5, 'AC1: with exactly 5 variables');
select is((select count(*)::int from public.report_delivery where channel_used = 'whatsapp' and template_name is null and tenant_id = :'tenant_id'), 0, 'AC1: no WhatsApp delivery exists without a template: free-form is never attempted');
select is((:'wa_variables'::jsonb) ->> 1, '1,800,000', 'AC3: 1800000 renders as 1,800,000');
select ok(:'wa_variables' !~ '1\.8M' and :'wa_variables' !~ '1800000', 'AC3: never as 1.8M or 1800000');
select is(app.fn_fmt_amount(180000000), '1,800,000', 'AC3: the shared formatter groups thousands');
select is(app.fn_fmt_amount(0), '0', 'AC3: and renders zero');
select public.record_digest_attempt_result(:'wa_delivery_id'::uuid, true, 'wamid.HBg1', null, false, :'slot20'::timestamptz + interval '2 minutes', null);
select is((select channel_used || '/' || provider_msg_id from public.report_delivery where id = :'wa_delivery_id'::uuid), 'whatsapp/wamid.HBg1', 'a WhatsApp send records its provider message id');

-- ── AC2: WhatsApp refuses -> SMS with the same figures inside 60 s ────────
select public.dispatch_due_digests(:'slot21'::timestamptz + interval '1 minute');
select delivery_id as wa21 from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '1 minute') where channel = 'whatsapp' \gset
select public.record_digest_attempt_result(:'wa21'::uuid, false, null, 'Message failed to send because more than 24 hours have passed', false, :'slot21'::timestamptz + interval '1 minute', '131047');
select is((select channel_used from public.report_delivery where fallback_of = :'wa21'::uuid), 'sms', 'AC2: a re-engagement error produces an SMS delivery with channel_used = sms');
select is((select count(*)::int from public.report_delivery where fallback_of = :'wa21'::uuid), 1, 'AC2: fallback_of points at the WhatsApp attempt');
select ok((select next_attempt_at <= :'slot21'::timestamptz + interval '2 minutes' from public.report_delivery where fallback_of = :'wa21'::uuid), 'AC2: and it is due within 60 seconds of the failure');
select * from public.claim_digest_deliveries(10, :'slot21'::timestamptz + interval '1 minute 30 seconds') where channel = 'sms' and to_msisdn = '+923001112233' \gset sms_
select ok(:'sms_body' like '%PKR 1,800,000%' and :'sms_body' like '%1,000 students%', 'AC2: the SMS carries the same figures');
select public.record_digest_attempt_result(:'sms_delivery_id'::uuid, true, 'sms-prov-1', null, false, :'slot21'::timestamptz + interval '2 minutes', null);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select last_channel_used || '/' || last_was_fallback::text from public.v_report_subscription_status where id = :'sub_wa_fb'), 'sms/true', 'the status screen shows the SMS fallback carried it');
reset role;

-- a template error also falls back; a transient error just retries on WhatsApp
select public.dispatch_due_digests(:'slot22'::timestamptz + interval '1 minute');
select delivery_id as wa22 from public.claim_digest_deliveries(10, :'slot22'::timestamptz + interval '1 minute') where channel = 'whatsapp' \gset
select public.record_digest_attempt_result(:'wa22'::uuid, false, null, 'HTTP 503 from Meta', true, :'slot22'::timestamptz + interval '1 minute', null);
select is((select channel_used || '/' || template_name from public.report_delivery where subscription_id = :'sub_wa_retry' and attempt_no = 2), 'whatsapp/daily_summary_v1', 'a transient WhatsApp error retries on WhatsApp, still as a template');
select is((select count(*)::int from public.report_delivery where fallback_of is not null and subscription_id = :'sub_wa_retry'), 0, 'and does not fall back to SMS');
select ok(app.fn_wa_fallback_error('132001') and app.fn_wa_fallback_error('131047') and not app.fn_wa_fallback_error('130429'), 'template and re-engagement codes trigger the fallback; rate limits do not');

-- the template was withdrawn after the subscription was saved: never free-form, SMS instead
update public.wa_template set status = 'PAUSED' where tenant_id = :'tenant_id' and language = 'en';
select public.dispatch_due_digests(:'slot23'::timestamptz + interval '1 minute');
select is((select channel_used from public.report_delivery where subscription_id = (select id from public.report_subscription where language_code = 'ur' and tenant_id = :'tenant_id') and scheduled_for = :'slot23'::timestamptz), 'whatsapp', 'an approved Urdu template still sends as a template');
select is((select count(*)::int from public.report_delivery where channel_used = 'sms' and tenant_id = :'tenant_id' and fallback_of is null and attempt_no = 1), 0, 'sanity: no early SMS yet');
delete from public.report_delivery where tenant_id = :'tenant_id' and scheduled_for = :'slot20'::timestamptz;
select public.dispatch_due_digests(:'slot20'::timestamptz + interval '3 minutes');
select is((select channel_used from public.report_delivery where subscription_id = :'sub_wa' and attempt_no = 1), 'sms', 'a withdrawn template at send time degrades to SMS instead of free-form WhatsApp');

-- ── privacy: another user cannot read a recipient's variables ─────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.report_delivery), 0, 'no client-side read of another user''s delivery variables');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text, true);
select throws_ok(format($$ select public.seed_digest_wa_templates(%L) $$, :'tenant_id'), '42501', 'FORBIDDEN', 'another school''s owner cannot register templates on this tenant');
reset role;

select * from finish();
rollback;
