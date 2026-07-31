-- pgTAP tests for FR-A18: tenant branding assets.
begin;
select plan(21);

select public.provision_tenant('test-branding-co', 'Branding Co', 'owner@brandingco.test');
select id as tenant_id from public.tenant where slug = 'test-branding-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_campus('SOUTH', 'Campus South', null) as _unused \gset
select id as campus_south from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'campus_south'))::text,
  true
);

-- ── AC1/AC2: resolution and size validation ────────────────────────────

select throws_ok(
  $$ select public.create_branding_asset('logo'::public.branding_asset_type, 400, 300, 50000, 'image/jpeg', 'jpg') $$,
  'ASSET_RESOLUTION_TOO_LOW',
  'AC1: a 400px-wide logo is rejected as too low resolution'
);
select throws_ok(
  $$ select public.create_branding_asset('logo'::public.branding_asset_type, 800, 600, 3565158, 'image/jpeg', 'jpg') $$,
  'ASSET_TOO_LARGE',
  'AC2: a 3.4MB file is rejected as too large'
);
select throws_ok(
  $$ select public.create_branding_asset('logo'::public.branding_asset_type, 800, 600, 50000, 'application/pdf', 'pdf') $$,
  'UNSUPPORTED_FILE_TYPE',
  'a non-image file is refused'
);

-- ── AC3: campus-then-tenant fallback ─────────────────────────────────

-- No branding anywhere yet — resolves to nothing, the caller falls back
-- to text with no broken-image placeholder.
select is(public.resolve_branding(:'campus_id'::uuid, 'logo'::public.branding_asset_type), null, 'AC3: no logo anywhere resolves to null, not an error');

-- A tenant-level logo (campus_id null) is uploaded and confirmed.
select public.create_branding_asset('logo'::public.branding_asset_type, 800, 600, 50000, 'image/jpeg', 'jpg') as tenant_logo \gset
select (:'tenant_logo'::jsonb ->> 'asset_id') as tenant_logo_id \gset
select public.confirm_branding_asset(:'tenant_logo_id'::uuid);
select is(
  ((public.resolve_branding(:'campus_south'::uuid, 'logo'::public.branding_asset_type))->>'asset_id')::uuid,
  :'tenant_logo_id'::uuid,
  'AC3: a campus with no logo of its own falls back to the tenant-level logo'
);

-- Campus GUL (:campus_id) gets its own logo — it must win over the
-- tenant fallback for that campus only.
select public.create_branding_asset('logo'::public.branding_asset_type, 900, 700, 60000, 'image/png', 'png', :'campus_id'::uuid) as gul_logo \gset
select (:'gul_logo'::jsonb ->> 'asset_id') as gul_logo_id \gset
select public.confirm_branding_asset(:'gul_logo_id'::uuid);
select is(
  ((public.resolve_branding(:'campus_id'::uuid, 'logo'::public.branding_asset_type))->>'asset_id')::uuid,
  :'gul_logo_id'::uuid,
  'AC3: campus GUL resolves its own logo, not the tenant fallback'
);
select is(
  ((public.resolve_branding(:'campus_south'::uuid, 'logo'::public.branding_asset_type))->>'asset_id')::uuid,
  :'tenant_logo_id'::uuid,
  'AC3: campus South (no logo of its own) still falls back to the tenant logo'
);

-- ── AC4: replacing a logo never touches a previously-generated
--    challan's payload ─────────────────────────────────────────────

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as tuition_line_id \gset
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Branding Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, '2026-08-01'::date, false) as gen_result \gset
select id as challan_id from public.fee_challan where enrolment_id = :'enrol_id' \gset

select public.set_challan_template(:'campus_id'::uuid, 'Test Bank', 'Branding Co', '1234567890');

select public.build_challan_render_payload(:'challan_id'::uuid) as payload_before \gset
select is(
  ((:'payload_before'::jsonb -> 'logo')->>'asset_id')::uuid,
  :'gul_logo_id'::uuid,
  'AC4: the challan''s payload embeds the logo that was current when it was generated'
);

-- Replace campus GUL's logo with a new version.
select public.create_branding_asset('logo'::public.branding_asset_type, 1000, 800, 70000, 'image/jpeg', 'jpg', :'campus_id'::uuid) as gul_logo_v2 \gset
select (:'gul_logo_v2'::jsonb ->> 'asset_id') as gul_logo_v2_id \gset
select public.confirm_branding_asset(:'gul_logo_v2_id'::uuid);

select is(
  ((public.resolve_branding(:'campus_id'::uuid, 'logo'::public.branding_asset_type))->>'asset_id')::uuid,
  :'gul_logo_v2_id'::uuid,
  'live resolution now returns the new version'
);
select ok(
  (select is_current from public.branding_asset where id = :'gul_logo_id'::uuid) = false,
  'the old version is superseded, not deleted'
);
select ok(
  (select storage_path from public.branding_asset where id = :'gul_logo_id'::uuid) is not null,
  'the old version''s storage object reference still exists'
);

select public.build_challan_render_payload(:'challan_id'::uuid) as payload_after \gset
select is(
  ((:'payload_after'::jsonb -> 'logo')->>'asset_id')::uuid,
  :'gul_logo_id'::uuid,
  'AC4: the SAME challan''s payload still shows the OLD logo — untouched by the replacement'
);

-- ── AC5: signed link without a public bucket ─────────────────────────

-- storage.buckets has RLS enabled with zero policies (invisible to
-- every role including authenticated, same posture as every table in
-- this codebase with "no read API") — read it as the migration-applying
-- role, not authenticated, same bracket other tests use for admin-only
-- cross-role reads.
reset role;
select is(
  (select public from storage.buckets where id = 'branding'),
  false,
  'AC5: the branding bucket is private — a "no session" viewer can only ever reach an object via a signed URL'
);
set local role authenticated;

-- ── idempotent versioning and the delete-on-abandon path ─────────────

select is(
  (select version from public.branding_asset where id = :'gul_logo_v2_id'::uuid),
  2,
  'the replacement is recorded as version 2 for that campus/asset_type'
);

select public.create_branding_asset('signature'::public.branding_asset_type, 300, 200, 20000, 'image/png', 'png') as sig_reservation \gset
select (:'sig_reservation'::jsonb ->> 'asset_id') as sig_id \gset
select public.delete_branding_asset(:'sig_id'::uuid);
select is((select count(*)::int from public.branding_asset where id = :'sig_id'::uuid), 0, 'an abandoned (never-confirmed) reservation can be deleted');

select public.confirm_branding_asset(:'tenant_logo_id'::uuid);
select throws_ok(
  format('select public.delete_branding_asset(%L)', :'tenant_logo_id'),
  'ASSET_NOT_DELETABLE',
  'a live (is_current) asset cannot be deleted directly'
);

-- ── theme ──────────────────────────────────────────────────────────

select public.set_tenant_theme('#112233', '#445566');
select is((select primary_hex from public.tenant_theme where tenant_id = :'tenant_id'), '#112233', 'the tenant theme is saved');
select throws_ok(
  $$ select public.set_tenant_theme('not-a-hex', null) $$,
  'new row for relation "tenant_theme" violates check constraint "tenant_theme_primary_hex_check"',
  'an invalid hex colour is rejected'
);

-- ── validation and tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  $$ select public.create_branding_asset('logo'::public.branding_asset_type, 800, 600, 50000, 'image/jpeg', 'jpg') $$,
  'FORBIDDEN',
  'a role with no branding authority cannot upload'
);

reset role;
select public.provision_tenant('test-branding-other-co', 'Branding Other Co', 'owner@brandingotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-branding-other-co' \gset
select gen_random_uuid() as other_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_user_id', 'owner@brandingotherco2.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_user_id', :'other_tenant_id', 'owner', 'Other Tenant Owner');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json, 'sub', :'other_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.branding_asset),
  0,
  'AC/defense-in-depth: another tenant sees zero branding assets via RLS'
);
select is(
  public.resolve_branding(:'campus_id'::uuid, 'logo'::public.branding_asset_type),
  null,
  'AC/defense-in-depth: another tenant cannot resolve this tenant''s branding, even by guessing the campus id'
);

select * from finish();
rollback;
