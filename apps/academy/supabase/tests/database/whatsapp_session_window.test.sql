-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M05: WhatsApp session window enforcement
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(18);

-- ─── 1. Setup Fixtures ─────────────────────────────────────────────────
select public.provision_tenant('test-wa-window', 'WhatsApp Academy', 'owner@wawindow.test');
select id as tenant_id from public.tenant where slug = 'test-wa-window' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset
select public.seed_default_wa_templates(:'tenant_id'::uuid);

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'wa_template', 'Table wa_template exists');
select has_table('public', 'wa_session_window', 'Table wa_session_window exists');
select has_table('public', 'wa_inbound_message', 'Table wa_inbound_message exists');
select has_table('public', 'wa_compliance_alert', 'Table wa_compliance_alert exists');

select has_column('public', 'message', 'wa_template_id', 'message has wa_template_id column');
select has_column('public', 'message', 'is_freeform', 'message has is_freeform column');

-- ─── 3. Default Seed Templates Check ───────────────────────────────────
select ok(
  exists (
    select 1
    from public.wa_template
    where tenant_id = :'tenant_id'::uuid
      and meta_template_name = 'student_absence_v1'
      and status = 'APPROVED'
  ),
  'Default Meta approved template exists for tenant'
);

-- ─── 4. FR-M05 AC 1: 24-Hour Session Window & Fallback ─────────────────
-- Given the last inbound message from a parent was 23h50m ago, when free-form
-- content is dispatched, then it is accepted; given the same payload at 24h01m,
-- then it is rejected with WA_WINDOW_CLOSED and falls back per FR-M02.

-- 4a. Inbound at 23h50m ago (window still active: 10 minutes remaining)
select public.process_wa_inbound_message(
  :'tenant_id'::uuid,
  '+923001112233',
  'Yes, I will be attending the meeting',
  'wam_valid_001',
  clock_timestamp() - interval '23 hours 50 minutes'
);

select is(
  public.wa_window_open(:'tenant_id'::uuid, '+923001112233'),
  true,
  'FR-M05 AC 1a: WhatsApp session window is open at 23h50m'
);

-- Create freeform message for this recipient
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, is_freeform
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923001112233', 'whatsapp',
  'Thank you for confirming, see you at 10 AM.', 'queued', true
) returning id as msg_valid_freeform_id \gset

select is(
  (public.validate_wa_dispatch(:'msg_valid_freeform_id'::uuid) ->> 'valid')::boolean,
  true,
  'FR-M05 AC 1a: Free-form dispatch accepted within 24-hour window'
);

-- 4b. Inbound at 24h01m ago (window expired 1 minute ago)
select public.process_wa_inbound_message(
  :'tenant_id'::uuid,
  '+923004445566',
  'Hello school',
  'wam_expired_002',
  clock_timestamp() - interval '24 hours 1 minute'
);

select is(
  public.wa_window_open(:'tenant_id'::uuid, '+923004445566'),
  false,
  'FR-M05 AC 1b: WhatsApp session window is closed at 24h01m'
);

insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, is_freeform
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923004445566', 'whatsapp',
  'Freeform reminder text sent outside window.', 'queued', true
) returning id as msg_expired_freeform_id \gset

select is(
  (public.validate_wa_dispatch(:'msg_expired_freeform_id'::uuid) ->> 'error'),
  'WA_WINDOW_CLOSED',
  'FR-M05 AC 1b: Free-form dispatch rejected with WA_WINDOW_CLOSED'
);

-- Verify fallback per FR-M02: SMS attempt created
select ok(
  exists (
    select 1
    from public.message_attempt
    where message_id = :'msg_expired_freeform_id'::uuid
      and channel = 'sms'
  ),
  'FR-M05 AC 1b: Dispatch fell back to SMS attempt per FR-M02'
);

-- ─── 5. FR-M05 AC 2: Block PENDING or REJECTED Template Attachment ─────
-- Given a WhatsApp template in PENDING or REJECTED state, when a user attaches it
-- to a campaign, then attachment is blocked with the current Meta status shown.

-- Fetch PENDING template ID
select id as pending_tmpl_id
from public.wa_template
where tenant_id = :'tenant_id'::uuid and status = 'PENDING' limit 1 \gset

-- Create dummy message to test attachment
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923007778899', 'whatsapp', 'Campaign text', 'queued'
) returning id as msg_attach_test_id \gset

-- Test attachment of PENDING template -> should throw 22023 with status PENDING
select throws_matching(
  format('select public.attach_wa_template_to_message(%L, %L)', :'msg_attach_test_id', :'pending_tmpl_id'),
  'current Meta status is PENDING',
  'FR-M05 AC 2a: Attaching PENDING WhatsApp template is blocked'
);

-- Fetch REJECTED template ID
select id as rejected_tmpl_id
from public.wa_template
where tenant_id = :'tenant_id'::uuid and status = 'REJECTED' limit 1 \gset

-- Test attachment of REJECTED template -> should throw 22023 with status REJECTED
select throws_matching(
  format('select public.attach_wa_template_to_message(%L, %L)', :'msg_attach_test_id', :'rejected_tmpl_id'),
  'current Meta status is REJECTED',
  'FR-M05 AC 2b: Attaching REJECTED WhatsApp template is blocked'
);

-- ─── 6. FR-M05 AC 3: Status Sync & Automatic Pause on Rejection ────────
-- Given a template transitions to REJECTED between scheduling and dispatch,
-- when the status sync runs, then any scheduled campaign using it is paused
-- and the Principal is notified within 1 hour.

-- Create an approved template to simulate mid-term transition
insert into public.wa_template (
  tenant_id, meta_template_name, category, status, body_text
) values (
  :'tenant_id'::uuid, 'term_announcement_v1', 'UTILITY', 'APPROVED',
  'Dear Parent, exam datesheet is available on portal.'
) returning id as dynamic_tmpl_id \gset

-- Create scheduled message using this template
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, wa_template_id
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923008889900', 'whatsapp',
  'Dear Parent, exam datesheet is available on portal.', 'queued', :'dynamic_tmpl_id'::uuid
) returning id as scheduled_msg_id \gset

-- Simulate Meta status sync transitioning template to REJECTED
select public.sync_wa_template_status(
  :'dynamic_tmpl_id'::uuid,
  'REJECTED'::public.wa_template_status,
  'Meta policy change: Variable formatting non-compliant'
);

-- Verify scheduled message is paused/cancelled
select is(
  (select status from public.message where id = :'scheduled_msg_id'::uuid),
  'cancelled'::public.message_status,
  'FR-M05 AC 3: Scheduled message is safely paused when template is rejected'
);

-- Verify Principal alert was generated in wa_compliance_alert
select ok(
  exists (
    select 1
    from public.wa_compliance_alert
    where tenant_id = :'tenant_id'::uuid
      and template_id = :'dynamic_tmpl_id'::uuid
      and alert_type = 'TEMPLATE_REJECTED'
  ),
  'FR-M05 AC 3: Principal alert created in wa_compliance_alert'
);

-- ─── 7. FR-M05 AC 4: No Inbound History -> Approved Template Used, No Window Row
-- Given the recipient's msisdn has never sent an inbound message, when dispatch runs,
-- then only an approved template is used and no session window row is created.

select id as approved_absence_tmpl_id
from public.wa_template
where tenant_id = :'tenant_id'::uuid and meta_template_name = 'student_absence_v1' \gset

-- Create message for completely brand-new recipient who never messaged school
insert into public.message (
  tenant_id, campus_id, recipient_phone, channel, body, status, wa_template_id
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, '+923009990011', 'whatsapp',
  'Dear Parent, Ali was marked absent on Monday.', 'queued', :'approved_absence_tmpl_id'::uuid
) returning id as msg_brand_new_id \gset

-- Validate dispatch
select is(
  (public.validate_wa_dispatch(:'msg_brand_new_id'::uuid) ->> 'valid')::boolean,
  true,
  'FR-M05 AC 4: Template-backed dispatch to unengaged parent is valid'
);

-- Verify NO session window row is created
select is(
  (select count(*) from public.wa_session_window where tenant_id = :'tenant_id'::uuid and msisdn = '+923009990011'),
  0::bigint,
  'FR-M05 AC 4: No session window row created for recipient with zero inbound history'
);

select * from finish();
rollback;
