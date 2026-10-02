-- pgTAP tests for FR-B05: dispatch automated follow-up and appointment
-- reminders.
begin;
select plan(21);

select public.provision_tenant('test-reminder-co', 'Reminder Co', 'owner@reminderco.test');
select id as tenant_id from public.tenant where slug = 'test-reminder-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

-- A real officer identity with a phone — admission_followup.assigned_to
-- is a not-null-required lookup target for the officer's own reminder.
select gen_random_uuid() as officer_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'officer_user_id', 'officer@reminderco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name, phone_e164)
values (:'officer_user_id', :'tenant_id', 'admissions_officer', 'Mr. Officer', '+923001112222');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- AC-adjacent: every new tenant is seeded with the default reminder
-- template registry (3 codes x 2 channels x 2 locales).
select is(
  (select count(*)::int from public.message_template where tenant_id = :'tenant_id'),
  12,
  'provision_tenant seeds the default reminder template registry'
);

-- ── AC1: exactly one outbound message row per follow-up, no matter how
--    many times the (would-be cron) queueing function runs ───────────

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate One', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One', p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry1_id \gset
select public.create_followup(:'enquiry1_id'::uuid, clock_timestamp() + interval '10 minutes', 'call'::public.followup_channel, :'officer_user_id'::uuid) as followup1_id \gset

select public.fn_queue_followup_reminders() as queued1 \gset
select is(:'queued1'::int, 1, 'AC: the due-soon follow-up is queued exactly once on the first run');
select public.fn_queue_followup_reminders() as queued2 \gset
select is(:'queued2'::int, 0, 'AC: re-running the queueing function creates no duplicate — the dedupe key absorbs the re-run');
select is(
  (select count(*)::int from public.outbound_message where followup_id = :'followup1_id'::uuid),
  1,
  'exactly one outbound_message row exists for this follow-up'
);
select is(
  (select channel from public.outbound_message where followup_id = :'followup1_id'::uuid)::text,
  'whatsapp',
  'the officer reminder is attempted over WhatsApp first'
);
select is(
  (select to_phone from public.outbound_message where followup_id = :'followup1_id'::uuid),
  '+923001112222',
  'the officer''s own phone number is resolved from app_user'
);

-- ── AC2: a permanent WhatsApp failure falls back to SMS once 5 minutes
--    have passed, and the original failure code is retained ──────────

select id as msg1_id from public.outbound_message where followup_id = :'followup1_id'::uuid \gset
select public.mark_outbound_message_failed(:'msg1_id'::uuid, 'META_PERMANENT_FAILURE');
select public.fn_process_sms_fallbacks() as fallback_too_soon \gset
select is(:'fallback_too_soon'::int, 0, 'no SMS fallback yet — 5 minutes have not passed');

reset role;
update public.outbound_message set created_at = clock_timestamp() - interval '6 minutes' where id = :'msg1_id'::uuid;
set local role authenticated;
select public.fn_process_sms_fallbacks() as fallback_ready \gset
select is(:'fallback_ready'::int, 1, 'AC: the SMS fallback is queued once 5 minutes have passed');
select is(
  (select count(*)::int from public.outbound_message where followup_id = :'followup1_id'::uuid and channel = 'sms'),
  1,
  'an SMS row now exists alongside the original WhatsApp attempt'
);
select is(
  (select failure_code from public.outbound_message where id = :'msg1_id'::uuid),
  'META_PERMANENT_FAILURE',
  'AC: the original WhatsApp row keeps its failure code — never cleared'
);

-- ── AC4: the parent's Urdu signal (child_name_ur) selects the
--    Urdu-approved template ───────────────────────────────────────────

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Two', p_child_name_ur => 'کینڈیڈیٹ دو', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two', p_phone => '03002222222', p_whatsapp_opt_in => true, p_source => 'walk_in') as enquiry2_id \gset
select public.fn_submit_application(:'enquiry2_id'::uuid) as app2_id \gset
select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, clock_timestamp() + interval '2 hours', 5) as sitting_id \gset
select public.fn_allocate_test_seat(:'sitting_id'::uuid, :'app2_id'::uuid);

select public.fn_queue_appointment_reminders() as queued_appt1 \gset
select is(:'queued_appt1'::int, 1, 'the upcoming test sitting reminder is queued');
select is(
  (select locale from public.outbound_message where enquiry_id = :'enquiry2_id'::uuid),
  'ur',
  'AC: the Urdu-approved template locale is selected from the enquiry''s own child_name_ur signal'
);
select is(
  (select template_id from public.outbound_message where enquiry_id = :'enquiry2_id'::uuid),
  (select template_id from public.message_template where tenant_id = :'tenant_id' and code = 'test_reminder' and channel = 'whatsapp' and locale = 'ur'),
  'the queued row carries the exact Urdu WhatsApp template id from the registry'
);

-- ── AC3: a 3rd parent message within 24 hours is suppressed as
--    rate_capped, but still visible (a row is still written) ─────────

select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Three', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Three', p_phone => '03003333333', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry3_id \gset
select public.fn_submit_application(:'enquiry3_id'::uuid) as app3_id \gset

select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, clock_timestamp() + interval '3 hours', 5) as sitting3a_id \gset
select public.fn_allocate_test_seat(:'sitting3a_id'::uuid, :'app3_id'::uuid);
select public.create_test_sitting(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, clock_timestamp() + interval '4 hours', 5) as sitting3b_id \gset

reset role;
-- Two prior parent messages for enquiry3, seeded directly (simulating
-- two earlier queued reminders) so the 3rd hits the cap deterministically.
insert into public.outbound_message (tenant_id, campus_id, enquiry_id, reminder_kind, test_sitting_id, channel, locale, to_phone, status, dedupe_key)
values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'enquiry3_id'::uuid, 'appointment_parent', :'sitting3a_id'::uuid, 'sms', 'en', '03003333333', 'sent', 'seed-1'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'enquiry3_id'::uuid, 'appointment_parent', :'sitting3a_id'::uuid, 'sms', 'en', '03003333333', 'sent', 'seed-2');
set local role authenticated;

select public.fn_allocate_test_seat(:'sitting3b_id'::uuid, :'app3_id'::uuid);
select public.fn_queue_appointment_reminders() as queued_appt3 \gset
select is(:'queued_appt3'::int, 1, 'the 3rd reminder is still written as a row (just capped), so the queue count includes it');
select is(
  (select status from public.outbound_message where enquiry_id = :'enquiry3_id'::uuid and reminder_kind = 'appointment_parent' and dedupe_key not in ('seed-1', 'seed-2'))::text,
  'rate_capped',
  'AC: the 3rd parent message in 24 hours is suppressed with status rate_capped'
);
select is(
  (select count(*)::int from public.outbound_message where enquiry_id = :'enquiry3_id'::uuid),
  3,
  'AC: the rate-capped message remains visible to the officer, not silently dropped'
);

-- A 2nd tenant1 follow-up, due now but never queued yet by tenant1 — used
-- below to prove the other tenant's owner cannot enqueue it.
select public.create_enquiry(p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Candidate Four', p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Four', p_phone => '03004444444', p_whatsapp_opt_in => false, p_source => 'walk_in') as enquiry4_id \gset
select public.create_followup(:'enquiry4_id'::uuid, clock_timestamp() + interval '5 minutes', 'call'::public.followup_channel, :'officer_user_id'::uuid) as followup4_id \gset

-- ── validation and tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  $$ select public.fn_queue_followup_reminders() $$,
  'FORBIDDEN',
  'a role with no admissions access cannot run the reminder queue'
);

reset role;
select public.provision_tenant('test-reminder-other-co', 'Reminder Other Co', 'owner@reminderotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-reminder-other-co' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@reminderotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.outbound_message),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero outbound messages via RLS'
);
select is(
  (select count(*)::int from public.message_template),
  12,
  'the other tenant sees only its own 12 seeded templates, not the first tenant''s'
);

-- AC/defense-in-depth (adversarial-review finding): an authenticated
-- officer of one tenant running the queue must never enqueue or touch
-- another tenant's due follow-up, even though both functions are
-- granted to `authenticated`, not just `service_role`.
select public.fn_queue_followup_reminders() as other_tenant_queued \gset
select is(:'other_tenant_queued'::int, 0, 'the other tenant''s owner queues nothing — they have no due follow-ups of their own');
reset role;
select is(
  (select count(*)::int from public.outbound_message where followup_id = :'followup4_id'::uuid),
  0,
  'AC/defense-in-depth: tenant1''s still-due follow-up was NOT enqueued by another tenant''s authenticated run'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);

select * from finish();
rollback;
