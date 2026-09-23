-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module M: Communication
-- FR-M03: Versioned template library
-- FR-M04: Urdu bodies and SMS segment costing
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(21);

-- ─── 1. Setup Fixtures ─────────────────────────────────────────────────
select public.provision_tenant('test-tmpl-lib', 'Template Academy', 'owner@tmpllib.test');
select id as tenant_id from public.tenant where slug = 'test-tmpl-lib' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset

select public.seed_default_versioned_templates(:'tenant_id'::uuid);

-- ─── 2. Schema Integrity Checks ────────────────────────────────────────
select has_table('public', 'message_template', 'Table message_template exists');
select has_table('public', 'message_template_version', 'Table message_template_version exists');
select has_table('public', 'template_placeholder', 'Table template_placeholder exists');

select has_column('public', 'message_template', 'audience_entity', 'message_template has audience_entity column');
select has_column('public', 'message_template', 'category', 'message_template has category column');
select has_column('public', 'message_template_version', 'sms_encoding', 'message_template_version has sms_encoding column');
select has_column('public', 'message', 'segment_count', 'message has generated segment_count column');

-- ─── 3. FR-M04: SMS Segment Counting Math ──────────────────────────────
-- AC 1: 140-character Urdu body = 3 segments (UCS-2)
select is(
  public.sms_segment_count(repeat('ا', 140)),
  3,
  'FR-M04 AC 1: 140-char Urdu body computes to 3 UCS-2 segments'
);

-- AC 2a: 155-character English body = 1 segment (GSM-7)
select is(
  public.sms_segment_count(repeat('A', 155)),
  1,
  'FR-M04 AC 2a: 155-char English body computes to 1 GSM-7 segment'
);

-- AC 2b: 155-char English + 1 Urdu character = 3 segments (UCS-2)
select is(
  public.sms_segment_count(repeat('A', 155) || 'ہ'),
  3,
  'FR-M04 AC 2b: 155-char English with 1 Urdu char appends into 3 UCS-2 segments'
);

-- AC 4: 150-character Roman-Urdu body = 1 segment (GSM-7)
select is(
  public.sms_segment_count('Mohtaram Walidain, aap kay bachay ki fee challan generate ho chuki hai. Meharbani farma kar waqt par adaigi karein taakay late fee say bacha ja sakay. Shukriya.'),
  1,
  'FR-M04 AC 4: 150-char Roman-Urdu body computes to 1 GSM-7 segment'
);

-- ─── 4. FR-M03 AC 1: Whitelist Enforcement ─────────────────────────────
-- Create template for audience 'student'
insert into public.message_template (tenant_id, name, audience_entity, category)
values (:'tenant_id'::uuid, 'Transport Test Template', 'student', 'general')
returning id as transport_tmpl_id \gset

-- Insert version containing unresolvable token {{bus_route}}
insert into public.message_template_version (
  template_id, version_no, body_en, sms_encoding
) values (
  :'transport_tmpl_id'::uuid, 1, 'Dear {{student_name}}, your bus route is {{bus_route}}.', 'auto'
)
returning id as bad_version_id \gset

-- validate_template_tokens directly identifies 'bus_route'
select is(
  (
    select array_agg(t order by t)
    from public.validate_template_tokens(:'bad_version_id'::uuid) t
  ),
  ARRAY['bus_route']::text[],
  'validate_template_tokens identifies bus_route as invalid for student entity'
);

-- Attempting publish rejects with SQLSTATE 22023 naming unresolvable token
select throws_ok(
  format('select public.publish_template_version(%L::uuid)', :'bad_version_id'),
  '22023',
  'Cannot publish template version: unresolvable placeholder token(s): bus_route',
  'FR-M03 AC 1: Publication is rejected when template has unresolvable token {{bus_route}}'
);

-- ─── 5. FR-M03 AC 4: Trigger-Enforced Immutability ─────────────────────
insert into public.message_template (tenant_id, name, audience_entity, category)
values (:'tenant_id'::uuid, 'Fee Notification Template', 'guardian', 'fee')
returning id as fee_tmpl_id \gset

insert into public.message_template_version (
  template_id, version_no, body_en, sms_encoding
) values (
  :'fee_tmpl_id'::uuid, 1, 'Dear Guardian, fee of {{amount_due}} for {{student_name}} is due on {{due_date}}.', 'auto'
)
returning id as fee_v1_id \gset

-- Publish version 1
select public.publish_template_version(:'fee_v1_id'::uuid);

-- Direct update on published version body must be rejected by trigger
select throws_ok(
  format('update public.message_template_version set body_en = %L where id = %L::uuid', 'Tampered body', :'fee_v1_id'),
  '23514',
  'Published template versions are immutable. Create a new version instead.',
  'FR-M03 AC 4: Updating body of published version is rejected by trigger'
);

-- ─── 6. FR-M03 AC 2: Version Pinning & Multiple Versions ───────────────
-- Create version 2 with updated wording and publish it
insert into public.message_template_version (
  template_id, version_no, body_en, change_summary
) values (
  :'fee_tmpl_id'::uuid, 2, 'Updated notice: Fee {{amount_due}} for {{student_name}} is due on {{due_date}}. Contact {{school_phone}}.', 'Added school phone'
)
returning id as fee_v2_id \gset

select public.publish_template_version(:'fee_v2_id'::uuid);

-- Verify both versions exist and retain their respective contents
select is(
  (select count(*) from public.message_template_version where template_id = :'fee_tmpl_id'::uuid and is_published = true),
  2::bigint,
  'FR-M03 AC 2: Template has exactly 2 published versions'
);

-- ─── 7. FR-M03 AC 3: Strict Null Guard on Render ───────────────────────
-- Calling render_template when a placeholder token is missing/null throws SQLSTATE 22004
select throws_ok(
  format('select public.render_template(%L::uuid, %L::jsonb, %L)', :'fee_v1_id', '{"student_name": "Hamza Ali"}', 'en'),
  '22004',
  'Template rendering failed: token "{{amount_due}}" is missing or null in context',
  'FR-M03 AC 3: Missing token {{amount_due}} in context raises 22004 error'
);

-- When all tokens are provided, render succeeds cleanly without raw {{...}}
select is(
  public.render_template(
    :'fee_v1_id'::uuid,
    '{"student_name": "Hamza Ali", "amount_due": "12,000 PKR", "due_date": "2026-10-15"}'::jsonb,
    'en'
  ),
  'Dear Guardian, fee of 12,000 PKR for Hamza Ali is due on 2026-10-15.',
  'FR-M03 AC 3: Fully populated context renders clean message with zero placeholder leakage'
);

-- Verify version 1 renders version 1 body, version 2 renders version 2 body
select is(
  public.render_template(
    :'fee_v2_id'::uuid,
    '{"student_name": "Hamza Ali", "amount_due": "12,000 PKR", "due_date": "2026-10-15", "school_phone": "+92 51 1234567"}'::jsonb,
    'en'
  ),
  'Updated notice: Fee 12,000 PKR for Hamza Ali is due on 2026-10-15. Contact +92 51 1234567.',
  'FR-M03 AC 2: Version 2 renders version 2 specific content while version 1 remains unchanged'
);

-- ─── 8. Bilingual pick_body Functionality ──────────────────────────────
select id as absence_v1_id from public.message_template_version
where template_id = (select id from public.message_template where tenant_id = :'tenant_id'::uuid and name = 'Student Absence Alert')
limit 1 \gset

select is(
  public.pick_body(:'absence_v1_id'::uuid, 'en'),
  'Dear Guardian, {{student_name}} (Roll No: {{roll_no}}) of {{grade_level}} - {{section_name}} was marked absent on {{attendance_date}}. If this was unexpected, please contact {{campus_name}}.',
  'pick_body returns English body when lang=en'
);

select is(
  public.pick_body(:'absence_v1_id'::uuid, 'ur'),
  'محترم والدین، آپ کے بچے {{student_name}} (رول نمبر: {{roll_no}}) جماعت {{grade_level}} - {{section_name}} کو بتاریخ {{attendance_date}} غیر حاضر شمار کیا گیا ہے۔ معلومات کے لیے {{campus_name}} سے رابطہ فرمائیں۔',
  'pick_body returns Urdu body when lang=ur'
);

-- ─── 9. Generated Column in public.message ─────────────────────────────
insert into public.message (
  tenant_id, campus_id, channel, recipient_type, recipient_phone, body, template_version_id
) values (
  :'tenant_id'::uuid, :'campus_id'::uuid, 'sms', 'guardian', '+923001234567', repeat('ا', 140), :'fee_v1_id'::uuid
)
returning segment_count as inserted_seg \gset

select is(
  :'inserted_seg'::integer,
  3,
  'public.message automatically calculates stored segment_count = 3 for inserted 140-char Urdu body'
);

select * from finish();
rollback;
