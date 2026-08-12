-- pgTAP tests for FR-T01: certificate template designer per board.
--
-- The PDF itself is produced outside the database (headless Chromium, see
-- apps/academy/lib/pdf/render.ts) and AC4 is asserted on the real bytes in
-- e2e/certificate-template-designer.spec.ts. What is tested here is
-- everything the database owns: which merge fields activation accepts,
-- what an edit to an activated version does, how a campus falls back to
-- the tenant default, that only one version of a template can be active,
-- and who may author or activate at all.
begin;
select plan(44);

select public.provision_tenant('test-certtpl-co', 'Cert Template Co', 'owner@certtpl.test');
select id as tenant_id from public.tenant where slug = 'test-certtpl-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@certtpl.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Cert Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@certtpl.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Cert Principal');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.create_campus('SOUTH', 'Campus South', null) as _unused \gset
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

-- ── merge-field extraction ─────────────────────────────────────────────

select is(
  public.certificate_merge_fields('<p>{{student.name_en}} of {{ enrolment.class_name }}</p>'),
  array['enrolment.class_name', 'student.name_en'],
  'merge fields are extracted, trimmed and de-duplicated'
);
select is(
  public.certificate_merge_fields('<p>plain wording, no fields</p>'),
  '{}'::text[],
  'a body with no merge fields extracts to an empty array, not null'
);
select is(
  public.certificate_merge_fields('<p>{{ student name }}</p>'),
  array['student name'],
  'a malformed token is still extracted, so validation can reject it'
);

-- ── AC1: activation rejects an unknown merge field, naming it ──────────

select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'School Leaving Certificate',
  '<p>{{student.name_en}} ({{student.gr_number}}) blood group {{student.blood_group}}, serial {{issue.serial_no}}, issued {{issue.date}}, left {{enrolment.left_on}}.</p>',
  'FBISE', 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as bad_tpl \gset

select is(
  (public.validate_certificate_template(:'bad_tpl'::uuid) -> 'unknown_fields')::text,
  '["student.blood_group"]',
  'AC1: the validator names the offending field'
);
select is(
  (public.validate_certificate_template(:'bad_tpl'::uuid) ->> 'ok')::boolean,
  false,
  'AC1: and reports the template as not activatable'
);
select throws_ok(
  format($$ select public.activate_certificate_template(%L) $$, :'bad_tpl'),
  '23514',
  'MERGE_FIELD_NOT_ALLOWED',
  'AC1: activation is rejected'
);
select is(
  (select status::text from public.certificate_template where id = :'bad_tpl'),
  'draft',
  'AC1: and the template stays a draft'
);

-- student.blood_group is a real student column; it is absent from the
-- catalogue on purpose, which is the whole point of a curated whitelist.
select is(
  (select count(*)::int from public.certificate_type_field_catalog where field_path = 'student.blood_group'),
  0,
  'student.blood_group is deliberately not in the field catalogue'
);

-- ── required fields are the other half of the same gate ────────────────

select public.create_certificate_template(
  'transfer'::public.certificate_type,
  'Short TC',
  '<p>{{student.name_en}} has left.</p>',
  'FBISE', 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_b'::uuid
) as thin_tpl \gset

select is(
  (public.validate_certificate_template(:'thin_tpl'::uuid) -> 'missing_required_fields')::text,
  '["enrolment.left_on", "issue.date", "issue.serial_no", "student.gr_number"]',
  'a TC missing statutory fields lists every one of them'
);
select throws_ok(
  format($$ select public.activate_certificate_template(%L) $$, :'thin_tpl'),
  '23514',
  'MERGE_FIELD_REQUIRED_MISSING',
  'and cannot be activated'
);

-- ── a clean template activates ─────────────────────────────────────────

select public.save_certificate_template(
  :'bad_tpl'::uuid,
  'School Leaving Certificate',
  '<p>{{student.name_en}} ({{student.gr_number}}), serial {{issue.serial_no}}, issued {{issue.date}}, left {{enrolment.left_on}}.</p>',
  'A4'::public.certificate_page_size
) as fixed_tpl \gset

select is(:'fixed_tpl'::uuid, :'bad_tpl'::uuid, 'editing a DRAFT edits it in place — no new version');
select is(
  (public.validate_certificate_template(:'bad_tpl'::uuid) ->> 'ok')::boolean,
  true,
  'the corrected draft validates clean'
);
select is(
  public.activate_certificate_template(:'bad_tpl'::uuid),
  :'bad_tpl'::uuid,
  'and activates'
);
select is(
  (select status::text from public.certificate_template where id = :'bad_tpl'),
  'active',
  'the template is now active'
);
select is(
  (select merge_field_whitelist::text from public.certificate_template where id = :'bad_tpl'),
  '["enrolment.left_on", "issue.date", "issue.serial_no", "student.gr_number", "student.name_en"]',
  'activation freezes the fields that version actually uses onto the row'
);
select isnt(
  (select activated_at from public.certificate_template where id = :'bad_tpl'),
  null,
  'and stamps who activated it and when'
);

-- ── AC2: editing an active version forks a new draft ───────────────────

-- Get to v3 the way a school would: activate, edit, activate, edit.
select public.save_certificate_template(:'bad_tpl'::uuid, 'School Leaving Certificate',
  '<p>v2 {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'A4'::public.certificate_page_size) as v2 \gset
select public.activate_certificate_template(:'v2'::uuid) as _unused \gset
select public.save_certificate_template(:'v2'::uuid, 'School Leaving Certificate',
  '<p>v3 {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'A4'::public.certificate_page_size) as v3 \gset
select public.activate_certificate_template(:'v3'::uuid) as _unused \gset

select is(
  (select version from public.certificate_template where id = :'v3'),
  3,
  'the third activated version is v3'
);
select is(
  (select status::text from public.certificate_template where id = :'v3'),
  'active',
  'v3 is the active one'
);
select is(
  (select status::text from public.certificate_template where id = :'v2'),
  'retired',
  'activating v3 retired v2 rather than deleting it'
);

select public.save_certificate_template(:'v3'::uuid, 'School Leaving Certificate',
  '<p>v4 wording {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'A4'::public.certificate_page_size) as v4 \gset

select isnt(:'v4'::uuid, :'v3'::uuid, 'AC2: editing an ACTIVE version returns a different row');
select is(
  (select version from public.certificate_template where id = :'v4'),
  4,
  'AC2: which is v4'
);
select is(
  (select status::text from public.certificate_template where id = :'v4'),
  'draft',
  'AC2: and is a draft'
);
select is(
  (select status::text from public.certificate_template where id = :'v3'),
  'active',
  'AC2: v3 remains active until v4 is activated'
);
select is(
  (select body_html from public.certificate_template where id = :'v3'),
  '<p>v3 {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'AC2: v3''s wording is untouched, so an already-issued certificate never re-renders differently'
);

-- The trigger, not the RPC, is what makes that true — a raw UPDATE is
-- forked and cancelled just the same.
update public.certificate_template
   set body_html = '<p>tampered {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>'
 where id = :'v3';
select is(
  (select body_html from public.certificate_template where id = :'v3'),
  '<p>v3 {{student.name_en}} ({{student.gr_number}}) {{issue.serial_no}} {{issue.date}} {{enrolment.left_on}}</p>',
  'a direct UPDATE against an active version cannot change its wording either'
);
select is(
  (select count(*)::int from public.certificate_template
    where tenant_id = :'tenant_id' and campus_id = :'campus_a' and certificate_type = 'transfer' and status = 'draft'),
  2,
  'it forked a second draft instead'
);

select throws_ok(
  format($$ delete from public.certificate_template where id = %L $$, :'v3'),
  '55000',
  'TEMPLATE_NOT_DELETABLE',
  'an activated version cannot be deleted — FR-T03/T08 will point at it as evidence'
);

-- ── unique active template per group ───────────────────────────────────

select throws_ok(
  format($$ update public.certificate_template set status = 'active', activated_at = now() where id = %L $$, :'v4'),
  '23505',
  null,
  'two active versions of the same template cannot coexist'
);

-- ── AC3: campus-then-tenant fallback ───────────────────────────────────

select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'bonafide'::public.certificate_type),
  null,
  'AC3: with no bonafide template anywhere, resolution is null'
);

select public.create_certificate_template(
  'bonafide'::public.certificate_type, 'Bonafide Certificate',
  '<p>{{student.name_en}} is a bonafide student. Issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, null
) as tenant_bonafide \gset
select public.activate_certificate_template(:'tenant_bonafide'::uuid) as _unused \gset

select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'bonafide'::public.certificate_type),
  :'tenant_bonafide'::uuid,
  'AC3: a campus with no template of its own falls back to the tenant default'
);

select public.create_certificate_template(
  'bonafide'::public.certificate_type, 'Bonafide Certificate (Campus A)',
  '<p>Campus A: {{student.name_en}} is a bonafide student. Issued {{issue.date}}.</p>',
  null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as campus_bonafide \gset
select public.activate_certificate_template(:'campus_bonafide'::uuid) as _unused \gset

select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'bonafide'::public.certificate_type),
  :'campus_bonafide'::uuid,
  'AC3: once campus A has its own, that one wins'
);
select is(
  public.resolve_certificate_template(:'campus_b'::uuid, 'bonafide'::public.certificate_type),
  :'tenant_bonafide'::uuid,
  'AC3: campus B still falls back to the tenant default'
);

-- board and language are part of the key, and language never falls back.
select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'transfer'::public.certificate_type, 'FBISE'),
  :'v3'::uuid,
  'the FBISE transfer template resolves for its own board'
);
select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'transfer'::public.certificate_type, 'BISELHR'),
  null,
  'a different board does not silently get the FBISE wording'
);
select is(
  public.resolve_certificate_template(:'campus_a'::uuid, 'bonafide'::public.certificate_type, null, 'ur'::public.certificate_language),
  null,
  'an Urdu request never falls back to the English template'
);

-- ── role and campus gating ─────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select lives_ok(
  format($$ select public.create_certificate_template('character'::public.certificate_type, 'Character Certificate',
    '<p>{{student.name_en}} ({{student.gr_number}}) — {{issue.date}}</p>', null,
    'en'::public.certificate_language, 'A4'::public.certificate_page_size, %L) $$, :'campus_a'),
  'a Principal may author a template for their own campus'
);
select throws_ok(
  format($$ select public.create_certificate_template('character'::public.certificate_type, 'Character Certificate',
    '<p>{{student.name_en}}</p>', null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, %L) $$, :'campus_b'),
  'FORBIDDEN',
  'but not for a campus they are not scoped to'
);
select throws_ok(
  $$ select public.create_certificate_template('character'::public.certificate_type, 'Character Certificate',
    '<p>{{student.name_en}}</p>', null, 'en'::public.certificate_language, 'A4'::public.certificate_page_size, null) $$,
  'FORBIDDEN',
  'and not the tenant-wide default, which is an Owner/Super Admin object'
);
select is(
  public.resolve_certificate_template(:'campus_b'::uuid, 'bonafide'::public.certificate_type),
  null,
  'a Principal resolving a campus outside their scope gets nothing back'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  $$ select public.create_certificate_template('bonafide'::public.certificate_type, 'Nope', '<p>{{issue.date}}</p>') $$,
  'FORBIDDEN',
  'a role with no template authority cannot author one'
);
select throws_ok(
  format($$ select public.activate_certificate_template(%L) $$, :'v4'),
  'FORBIDDEN',
  'nor activate one'
);
select is(
  (select count(*)::int from public.certificate_template where tenant_id = :'tenant_id'),
  (select count(*)::int from public.certificate_template),
  'RLS keeps every visible template inside the caller''s own tenant'
);

-- ── the preview payload ────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (public.certificate_preview_payload(:'campus_bonafide'::uuid) -> 'sample_values' ->> 'student.name_en'),
  'Ahmed Raza',
  'the preview payload carries an English sample value per merge field'
);

select public.create_certificate_template(
  'bonafide'::public.certificate_type, 'اردو سرٹیفکیٹ',
  '<p>{{student.name_en}} — {{issue.date}}</p>',
  null, 'ur'::public.certificate_language, 'A4'::public.certificate_page_size, :'campus_a'::uuid
) as urdu_tpl \gset
select is(
  (public.certificate_preview_payload(:'urdu_tpl'::uuid) -> 'sample_values' ->> 'student.name_en'),
  'احمد رضا',
  'AC4: an Urdu template previews with Urdu sample values, so the glyph check has real content'
);

select * from finish();
rollback;
