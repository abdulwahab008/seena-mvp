-- pgTAP tests for FR-T15: consent capture for photos and data use.
--
-- Every assertion below goes through the same functions the application
-- calls — build_marketing_gallery_export() and
-- dispatch_absentee_notifications(), not a hand-rolled query that happens
-- to filter the same way. A consent test that asserts on the consent table
-- alone would pass just as happily if nothing enforced it.
begin;
select plan(52);

select public.provision_tenant('test-consent-co', 'Consent Co', 'owner@consentco.test');
select id as tenant_id from public.tenant where slug = 'test-consent-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

-- Real auth users so auth.uid() resolves for recorded_by and for the
-- guardian-portal branch of record_consent().
reset role;
select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner-user@consentco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id'::uuid, 'owner', 'Owner User');

select gen_random_uuid() as parent_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_user_id', 'parent-user@consentco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'parent_user_id', :'tenant_id'::uuid, 'parent', 'Parent User');

select gen_random_uuid() as super_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'super_user_id', 'super-user@consentco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'super_user_id', :'tenant_id'::uuid, 'super_admin', 'Platform Operator');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset

select public.create_student(:'campus_id'::uuid, 'Granted Kid', '2015-01-01'::date, 'male') as s_grant \gset
select public.enrol_student(:'section_a'::uuid, :'s_grant'::uuid) as e_grant \gset
select public.create_student(:'campus_id'::uuid, 'Denied Kid', '2015-01-01'::date, 'female') as s_deny \gset
select public.enrol_student(:'section_a'::uuid, :'s_deny'::uuid) as e_deny \gset
select public.create_student(:'campus_id'::uuid, 'Split Household Kid', '2015-01-01'::date, 'male') as s_split \gset
select public.enrol_student(:'section_a'::uuid, :'s_split'::uuid) as e_split \gset
select public.create_student(:'campus_id'::uuid, 'Never Asked Kid', '2015-01-01'::date, 'female') as s_silent \gset
select public.enrol_student(:'section_a'::uuid, :'s_silent'::uuid) as e_silent \gset
select public.create_student(:'campus_id'::uuid, 'Paper Form Kid', '2015-01-01'::date, 'male') as s_paper \gset
select public.enrol_student(:'section_a'::uuid, :'s_paper'::uuid) as e_paper \gset

reset role;
update public.student set photo_path = :'tenant_id' || '/photos/' || id::text || '.jpg'
 where id in (:'s_grant'::uuid, :'s_deny'::uuid, :'s_split'::uuid, :'s_silent'::uuid, :'s_paper'::uuid);

-- G1 is the parent-portal guardian (owns parent_user_id); the rest are
-- counter-recorded contacts.
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id)
values (:'tenant_id'::uuid, 'Guardian Grant', '+923001110001', :'parent_user_id'::uuid) returning id as g_grant \gset
insert into public.guardian (tenant_id, name_en, phone_e164)
values (:'tenant_id'::uuid, 'Guardian Deny', '+923001110002') returning id as g_deny \gset
insert into public.guardian (tenant_id, name_en, phone_e164)
values (:'tenant_id'::uuid, 'Guardian Split Father', '+923001110003') returning id as g_split_f \gset
insert into public.guardian (tenant_id, name_en, phone_e164)
values (:'tenant_id'::uuid, 'Guardian Split Mother', '+923001110004') returning id as g_split_m \gset
insert into public.guardian (tenant_id, name_en, phone_e164)
values (:'tenant_id'::uuid, 'Guardian Silent', '+923001110005') returning id as g_silent \gset
insert into public.guardian (tenant_id, name_en, phone_e164)
values (:'tenant_id'::uuid, 'Guardian Paper', '+923001110006') returning id as g_paper \gset

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values
  (:'tenant_id'::uuid, :'s_grant'::uuid,  :'g_grant'::uuid,   'father', true,  true),
  (:'tenant_id'::uuid, :'s_deny'::uuid,   :'g_deny'::uuid,    'father', true,  true),
  (:'tenant_id'::uuid, :'s_split'::uuid,  :'g_split_f'::uuid, 'father', true,  true),
  (:'tenant_id'::uuid, :'s_split'::uuid,  :'g_split_m'::uuid, 'mother', false, false),
  (:'tenant_id'::uuid, :'s_silent'::uuid, :'g_silent'::uuid,  'mother', true,  true),
  (:'tenant_id'::uuid, :'s_paper'::uuid,  :'g_paper'::uuid,   'father', true,  true);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- Default posture, before any decision is recorded
-- ═══════════════════════════════════════════════════════════════════════

select is(
  public.has_consent(:'s_silent'::uuid, 'student_photo_marketing'),
  false,
  'opt-in purpose: silence is not permission — a student nobody asked has no photo consent'
);
select is(
  public.has_consent(:'s_silent'::uuid, 'sms_messaging'),
  true,
  'opt-out purpose: transactional messaging keeps working for a student with no consent row'
);
select throws_like(
  format('select public.has_consent(%L::uuid, %L)', :'s_silent', 'not_a_real_purpose'),
  '%CONSENT_PURPOSE_NOT_FOUND%',
  'an unknown purpose is an error, never a silent true'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Recording decisions
-- ═══════════════════════════════════════════════════════════════════════

select public.record_consent(:'s_grant'::uuid, 'student_photo_marketing', :'g_grant'::uuid, 'granted', 'counter') as r_grant \gset
select public.record_consent(:'s_deny'::uuid, 'student_photo_marketing', :'g_deny'::uuid, 'denied', 'counter') as r_deny \gset
-- An explicit grant on a purpose whose wording changes are NOT material,
-- so AC3 can assert the negative case as well as the positive one.
select public.record_consent(:'s_grant'::uuid, 'sms_messaging', :'g_grant'::uuid, 'granted', 'counter');

select is(public.has_consent(:'s_grant'::uuid, 'student_photo_marketing'), true, 'a granted photo consent resolves to true');
select is(public.has_consent(:'s_deny'::uuid, 'student_photo_marketing'), false, 'a denied photo consent resolves to false');
select is(
  (:'r_grant'::jsonb ->> 'text_version')::int,
  1,
  'a new consent binds to the version of the wording in force today — v1, the platform default, for a school that has published none of its own'
);

select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_grant', 'student_photo_marketing', :'g_deny', 'granted', 'counter'),
  '%GUARDIAN_NOT_LINKED%',
  'a guardian who is not linked to the student cannot record a decision about them'
);

-- Changing one's mind: the register keeps the old row and points it at the
-- new one rather than editing or deleting it. The withdrawal-then-regrant
-- below leaves the same student granted again, so nothing downstream in
-- this file shifts.
select public.record_consent(:'s_grant'::uuid, 'third_party_data_sharing', :'g_grant'::uuid, 'granted', 'counter') as r_tp1 \gset
select public.record_consent(:'s_grant'::uuid, 'third_party_data_sharing', :'g_grant'::uuid, 'withdrawn', 'portal') as r_tp2 \gset

select is(
  public.has_consent(:'s_grant'::uuid, 'third_party_data_sharing'),
  false,
  'a later decision by the same guardian replaces the earlier one'
);
select is(
  (select superseded_by::text from public.consent_record where id = (:'r_tp1'::jsonb ->> 'consent_record_id')::uuid),
  (:'r_tp2'::jsonb ->> 'consent_record_id'),
  'the replaced decision is kept and linked to the one that replaced it, never edited away'
);
select is(
  (select count(*)::int from public.consent_record
    where student_id = :'s_grant'::uuid and purpose_code = 'third_party_data_sharing' and superseded_by is null),
  1,
  'exactly one decision per guardian is current at a time'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: two linked guardians disagree
-- ═══════════════════════════════════════════════════════════════════════

select public.record_consent(:'s_split'::uuid, 'student_photo_marketing', :'g_split_f'::uuid, 'granted', 'counter');
select public.record_consent(:'s_split'::uuid, 'student_photo_marketing', :'g_split_m'::uuid, 'denied', 'portal');

select is(
  public.has_consent(:'s_split'::uuid, 'student_photo_marketing'),
  false,
  'AC4: one guardian grants and one denies — the effective consent is DENIED'
);
select is(
  (select has_conflict from public.v_consent_attention
    where student_id = :'s_split'::uuid and purpose_code = 'student_photo_marketing'),
  true,
  'AC4: the disagreement is surfaced as a conflict for the Principal'
);
select is(
  (select granted_count || '/' || denied_count from public.v_consent_attention
    where student_id = :'s_split'::uuid and purpose_code = 'student_photo_marketing'),
  '1/1',
  'AC4: the conflict row names how many granted and how many denied'
);
select is(
  (select has_conflict from public.v_consent_attention
    where student_id = :'s_grant'::uuid and purpose_code = 'student_photo_marketing'),
  false,
  'AC4: a single agreeing guardian is not a conflict'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC5: paper capture with a scan
-- ═══════════════════════════════════════════════════════════════════════

select public.reserve_consent_evidence_path(:'s_paper'::uuid, 'pdf', 240000, 'application/pdf') as evidence_path \gset

select ok(
  :'evidence_path' like (:'tenant_id' || '/' || :'s_paper' || '/%.pdf'),
  'AC5: the reserved evidence path is scoped to the tenant and the student'
);
select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_paper', 'student_photo_marketing', :'g_paper', 'granted', 'paper'),
  '%EVIDENCE_REQUIRED%',
  'AC5: a paper capture with no scan attached is refused'
);
select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L, %L)',
         :'s_paper', 'student_photo_marketing', :'g_paper', 'granted', 'paper',
         :'tenant_id' || '/' || :'s_grant' || '/forged.pdf'),
  '%EVIDENCE_PATH_MISMATCH%',
  'AC5: a scan filed under another student''s folder is refused'
);

select public.record_consent(
  :'s_paper'::uuid, 'student_photo_marketing', :'g_paper'::uuid, 'granted', 'paper', :'evidence_path'
);

select is(
  public.has_consent(:'s_paper'::uuid, 'student_photo_marketing'),
  true,
  'AC5: a paper-channel consent is equally enforceable — has_consent() does not care how it arrived'
);
select is(
  (select channel || '|' || (evidence_path is not null)::text from public.consent_record
    where student_id = :'s_paper'::uuid and purpose_code = 'student_photo_marketing' and superseded_by is null),
  'paper|true',
  'AC5: the row records channel=paper with the scan attached'
);
select isnt(
  (select recorded_by from public.consent_record
    where student_id = :'s_paper'::uuid and purpose_code = 'student_photo_marketing' and superseded_by is null),
  null,
  'AC5: a paper capture names the officer who keyed it in'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the marketing gallery export
-- ═══════════════════════════════════════════════════════════════════════

select public.build_marketing_gallery_export(:'campus_id'::uuid) as gallery \gset
select (:'gallery'::jsonb ->> 'export_id') as export_id \gset

select is(
  (:'gallery'::jsonb ->> 'included')::int,
  2,
  'AC1: only the two students with a live grant are in the gallery'
);
select is(
  (:'gallery'::jsonb ->> 'excluded_consent_denied')::int,
  2,
  'AC1: the denied student and the split-household student are both excluded'
);
select is(
  (:'gallery'::jsonb ->> 'excluded_consent_not_recorded')::int,
  1,
  'AC1: a student nobody asked is excluded too, but not recorded as a denial'
);
select is(
  (select count(*)::int from public.marketing_gallery_export_item
    where export_id = :'export_id'::uuid and student_id = :'s_deny'::uuid),
  0,
  'AC1: the denied student is not in the export payload at all'
);
select is(
  (select count(*)::int from public.marketing_gallery_export_item
    where export_id = :'export_id'::uuid and student_id in (:'s_grant'::uuid, :'s_paper'::uuid)),
  2,
  'AC1: the granted and paper-consented students are in the export payload'
);
select is(
  (select reason from public.marketing_gallery_export_exclusion
    where export_id = :'export_id'::uuid and student_id = :'s_deny'::uuid),
  'consent_denied',
  'AC1: the exclusion is recorded with reason consent_denied'
);
select is(
  (select reason from public.marketing_gallery_export_exclusion
    where export_id = :'export_id'::uuid and student_id = :'s_silent'::uuid),
  'consent_not_recorded',
  'AC1: a never-asked student is excluded as not-recorded, not as a denial'
);

-- The audit row AC1 asks for. It is the ordinary app.tg_audit_row() row the
-- exclusion INSERT produced, so it is inside FR-T14's hash chain too.
select is(
  (select count(*)::int from public.audit_log
    where table_name = 'marketing_gallery_export_exclusion'
      and action = 'insert'
      and tenant_id = :'tenant_id'::uuid
      and after ->> 'reason' = 'consent_denied'
      and after ->> 'student_id' = :'s_deny'),
  1,
  'AC1: the attempt is written to audit_log with reason consent_denied'
);
select isnt(
  (select row_hash from public.audit_log
    where table_name = 'marketing_gallery_export_exclusion'
      and after ->> 'student_id' = :'s_deny' limit 1),
  null,
  'AC1: that audit row carries a chain hash, so the denial record cannot be quietly removed'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: withdrawal suppresses a real dispatch
-- ═══════════════════════════════════════════════════════════════════════

-- Section A's register is fully submitted for today: every active enrolment
-- has a row, present included.
reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source) values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'e_grant'::uuid,  current_date, 'absent',  'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'e_deny'::uuid,   current_date, 'absent',  'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'e_split'::uuid,  current_date, 'present', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'e_silent'::uuid, current_date, 'present', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'e_paper'::uuid,  current_date, 'present', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- The withdrawal, recorded from the portal by the guardian's own account.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_user_id')::text,
  true
);
select public.record_consent(:'s_grant'::uuid, 'whatsapp_messaging', :'g_grant'::uuid, 'withdrawn', 'portal');
select is(
  public.has_consent(:'s_grant'::uuid, 'whatsapp_messaging'),
  false,
  'AC2: a withdrawal takes effect the moment it is recorded'
);
select throws_like(
  format('select public.record_consent(%L::uuid, %L, %L::uuid, %L, %L)',
         :'s_grant', 'whatsapp_messaging', :'g_grant', 'granted', 'paper'),
  '%FORBIDDEN%',
  'a guardian cannot manufacture a paper capture from the portal'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.dispatch_absentee_notifications(:'campus_id'::uuid, current_date, 'whatsapp') as wa_run \gset
select is(
  (:'wa_run'::jsonb ->> 'skipped_no_consent')::int,
  1,
  'AC2: the WhatsApp broadcast reports one guardian skipped for want of consent'
);
select is(
  (:'wa_run'::jsonb ->> 'queued')::int,
  1,
  'AC2: the other absentee is still dispatched — suppression is per student, not a kill switch'
);
select is(
  (select status::text || '|' || coalesce(recipient_msisdn, '<none>') || '|' || cost_paisa::text
     from public.attendance_notification
    where enrolment_id = :'e_grant'::uuid and notification_date = current_date and channel = 'whatsapp'),
  'skipped_optout|<none>|0',
  'AC2: the skip is on the campaign report as skipped_optout, with no number and no cost'
);

-- The SMS run is the pre-existing two-argument call site, untouched: the
-- withdrawal was for WhatsApp only, so both absentees are still queued.
select public.dispatch_absentee_notifications(:'campus_id'::uuid, current_date) as sms_run \gset
select is(
  (:'sms_run'::jsonb ->> 'queued')::int,
  2,
  'AC2: withdrawing WhatsApp consent does not suppress SMS, and the two-argument call still resolves'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the wording is revised
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'super_user_id')::text,
  true
);
select public.publish_consent_text_version('student_photo_marketing', 'Revised v2 photo wording.') as v2 \gset
select public.publish_consent_text_version('student_photo_marketing', 'Revised v3 photo wording.') as v3 \gset
select public.publish_consent_text_version('sms_messaging', 'Revised v2 SMS wording.');

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select is(:'v3'::int, 3, 'AC3: publishing revised wording twice takes the purpose from v1 to v2 to v3');
select is(
  public.current_consent_text_version(gen_random_uuid(), 'student_photo_marketing'),
  1,
  'AC3: one school revising its own wording does not move any other school off v1'
);
select is(
  public.has_consent(:'s_grant'::uuid, 'student_photo_marketing'),
  true,
  'AC3: an existing v1 consent remains VALID after the wording moves to v3'
);
select is(
  (select text_version::text || '|' || (superseded_by is null)::text from public.consent_record
    where student_id = :'s_grant'::uuid and purpose_code = 'student_photo_marketing' and superseded_by is null),
  '1|true',
  'AC3: the stored row is untouched — not auto-invalidated and not auto-carried to v3'
);
select is(
  (select reconsent_required from public.v_consent_attention
    where student_id = :'s_grant'::uuid and purpose_code = 'student_photo_marketing'),
  true,
  'AC3: the old-version consent is FLAGGED reconsent_required for the admin dashboard'
);
select is(
  (select reconsent_required from public.v_consent_attention
    where student_id = :'s_grant'::uuid and purpose_code = 'sms_messaging'),
  false,
  'AC3: a purpose whose wording change is not material never asks for re-consent, even though its own text also moved to v2'
);
select is(
  (select effective::text || '|' || reconsent_required::text
     from public.consent_state_for_student(:'s_grant'::uuid) where purpose_code = 'student_photo_marketing'),
  'true|true',
  'AC3: the per-student view shows both facts at once — still effective, still needs re-consent'
);
select public.build_marketing_gallery_export(:'campus_id'::uuid) as gallery2 \gset
select is(
  (:'gallery2'::jsonb ->> 'included')::int,
  2,
  'AC3: the version bump did not silently drop anyone from the gallery'
);

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_user_id')::text,
  true
);

select is(
  (select count(distinct student_id)::int from public.consent_record),
  1,
  'consent_record_parent_read_own: a parent sees exactly one child''s consent rows'
);
select is(
  (select count(*)::int from public.consent_record where student_id = :'s_deny'::uuid),
  0,
  'consent_record_parent_read_own: another family''s consent rows are invisible'
);
select is(
  (select count(*)::int from public.guardian),
  1,
  'guardian_parent_read_self: a parent reads their own guardian row and no one else''s'
);
select is(
  (select count(*)::int from public.student_guardian where student_id = :'s_grant'::uuid),
  1,
  'student_guardian_parent_read_own: a parent reads their own link to their own child'
);
select is(
  (select count(*)::int from public.v_consent_guardian_decision where student_id = :'s_split'::uuid),
  0,
  'a parent sees no decisions for a child that is not theirs'
);
select throws_like(
  format($fmt$insert into public.consent_record (tenant_id, campus_id, student_id, purpose_code, decision, granted_by_guardian_id, channel, text_version) values (%L::uuid, %L::uuid, %L::uuid, 'student_photo_marketing', 'granted', %L::uuid, 'portal', 1)$fmt$,
         :'tenant_id', :'campus_id', :'s_grant', :'g_grant'),
  '%row-level security%',
  'consent_record_write_staff: a parent cannot write straight to the table, only through record_consent()'
);

with attempted as (delete from public.consent_record where student_id = :'s_grant'::uuid returning 1)
select is((select count(*)::int from attempted), 0, 'consent_record_no_delete: an authenticated delete removes nothing');

reset role;
select throws_like(
  format('delete from public.consent_record where student_id = %L::uuid', :'s_grant'),
  '%append-only%',
  'consent_record_no_delete: the register refuses a delete even from a caller RLS does not reach'
);
select throws_like(
  'truncate public.consent_record',
  '%append-only%',
  'consent_record_no_delete: TRUNCATE is refused too'
);

select * from finish();
rollback;
