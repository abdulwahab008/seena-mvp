-- pgTAP tests for FR-K03: fee structure versioning and effective dating.
begin;
select plan(19);

select public.provision_tenant('test-structure-ver-co', 'Structure Ver Co', 'owner@structverco.test');
select id as tenant_id from public.tenant where slug = 'test-structure-ver-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_id', 'realowner@structverco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_id', :'tenant_id', 'owner', 'Real Owner');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', :'owner_id', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id')
  )::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

-- ── version 1: TUITION at 500000 paisa, published ──────────────────────

select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as v1_id \gset
select public.add_structure_line(:'v1_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency) as v1_line_id \gset
select public.publish_fee_structure(:'v1_id'::uuid);

-- ── AC: a published structure's line cannot be edited directly ────────

reset role;
select throws_ok(
  format('update public.fee_structure_line set amount_paisa = 999999 where id = %L', :'v1_line_id'),
  'published structures are immutable; create version 2',
  'AC: a direct UPDATE on a published structure''s line is rejected with the exact message'
);
select throws_ok(
  format('delete from public.fee_structure_line where id = %L', :'v1_line_id'),
  'published structures are immutable; create version 2',
  'the same guard blocks DELETE, not just UPDATE'
);
select is(
  (select amount_paisa from public.fee_structure_line where id = :'v1_line_id'),
  500000::bigint,
  'the line''s amount is untouched by the rejected update attempt'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'owner_id', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── version 2: a modest 10% revision, effective 1 Jan ──────────────────

select public.create_next_structure_version(:'v1_id'::uuid, '2027-01-01'::date) as v2_id \gset
select is(
  (select count(*)::int from public.fee_structure_line where structure_id = :'v2_id'),
  1,
  'the new draft version starts as an exact clone of the prior published version''s lines'
);
select id as v2_line_id from public.fee_structure_line where structure_id = :'v2_id' \gset
select public.update_structure_line_amount(:'v2_line_id'::uuid, 550000::bigint);
select is(
  (select amount_paisa from public.fee_structure_line where id = :'v2_line_id'),
  550000::bigint,
  'AC: a draft line''s amount can be revised — 500000 -> 550000, a 10% increase'
);

-- update_structure_line_amount only works on a draft — sanity-check
-- against a published line via the same function (not just raw SQL).
select throws_ok(
  format('select public.update_structure_line_amount(%L, 1)', :'v1_line_id'),
  'STRUCTURE_NOT_DRAFT',
  'update_structure_line_amount refuses a published structure''s line too'
);

select public.publish_fee_structure(:'v2_id'::uuid);
select is(
  (select status::text from public.fee_structure where id = :'v1_id'),
  'superseded',
  'AC: publishing version 2 supersedes version 1'
);
select is(
  (select status::text from public.fee_structure where id = :'v2_id'),
  'published',
  'version 2 is now the published structure'
);
select is(
  (select version_no from public.fee_structure where id = :'v2_id'),
  2,
  'version_no incremented correctly'
);
select is(
  (select regulator_reference from public.fee_structure where id = :'v2_id'),
  null,
  'a 10% increase, under any (unset) cap, needed no regulator approval'
);

-- ── AC: resolve_fee_structure picks the version that was actually
--    effective on a given historical date ──────────────────────────────

select is(
  public.resolve_fee_structure(:'campus_id'::uuid, :'session_id'::uuid, '2026-12-01'::date),
  :'v1_id'::uuid,
  'AC: a December period resolves to version 1 (superseded, but correct for that date)'
);
select is(
  public.resolve_fee_structure(:'campus_id'::uuid, :'session_id'::uuid, '2027-01-15'::date),
  :'v2_id'::uuid,
  'AC: a January period resolves to version 2'
);

-- ── AC: an above-cap increase is blocked without a regulator reference ──

reset role;
insert into public.fee_policy (tenant_id, max_fee_increase_pct) values (:'tenant_id'::uuid, 5)
  on conflict (tenant_id) do update set max_fee_increase_pct = 5;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'owner_id', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_next_structure_version(:'v2_id'::uuid, '2027-04-01'::date) as v3_id \gset
select id as v3_line_id from public.fee_structure_line where structure_id = :'v3_id' \gset
-- 550000 -> 616000 is a 12% increase, over the 5% cap.
select public.update_structure_line_amount(:'v3_line_id'::uuid, 616000::bigint);

select throws_ok(
  format('select public.publish_fee_structure(%L)', :'v3_id'),
  'REGULATOR_REFERENCE_REQUIRED',
  'AC: a 12% average increase against a 5% cap is blocked without a regulator_reference'
);
select throws_ok(
  format('select public.publish_fee_structure(%L, ''ab'')', :'v3_id'),
  'REGULATOR_REFERENCE_REQUIRED',
  'a regulator reference under 4 characters is also rejected'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.publish_fee_structure(%L, ''PEIRA-2027-0042'')', :'v3_id'),
  'FORBIDDEN',
  'AC: even with a valid regulator_reference, an accountant cannot approve an above-cap increase — Owner/Super Admin only'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', :'owner_id', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.publish_fee_structure(:'v3_id'::uuid, 'PEIRA-2027-0042');
select is(
  (select regulator_reference from public.fee_structure where id = :'v3_id'),
  'PEIRA-2027-0042',
  'AC: publishing with a valid regulator_reference succeeds and the reference is recorded on the structure'
);
select isnt(
  (select approved_by from public.fee_structure where id = :'v3_id'),
  null,
  'the approving owner is recorded'
);
select is(
  (select round(avg_increase_pct) from public.fee_increase_approval where structure_id = :'v3_id'),
  12::numeric,
  'AC: the approval record captures the actual average increase (12%)'
);

-- ── access control ──────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.create_next_structure_version(%L, ''2027-07-01''::date)', :'v3_id'),
  'FORBIDDEN',
  'a teacher cannot create a new structure version'
);

select * from finish();
rollback;
