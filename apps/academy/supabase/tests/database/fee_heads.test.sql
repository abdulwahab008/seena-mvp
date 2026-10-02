-- pgTAP tests for FR-K01: fee head master data.
begin;
select plan(9);

select public.provision_tenant('test-fee-heads-co', 'Fee Heads Co', 'owner@feeheadsco.test');
select id as tenant_id from public.tenant where slug = 'test-fee-heads-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── seeding ────────────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.fee_head where tenant_id = :'tenant_id'),
  0,
  'a freshly provisioned tenant starts with zero fee heads'
);
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select is(
  (select count(*)::int from public.fee_head where tenant_id = :'tenant_id'),
  8,
  'seeding a tenant with no fee heads creates exactly 8'
);
select is(
  (select is_refundable from public.fee_head where tenant_id = :'tenant_id' and code = 'SECURITY_DEPOSIT'),
  true,
  'the security deposit head is flagged refundable — segregated from revenue at the schema level'
);
select is(
  (select is_refundable from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION'),
  false,
  'tuition is not refundable'
);

-- ── FORBIDDEN: a non-finance role cannot manage fee heads ───────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.create_fee_head('CUSTOM', 'Custom Fee', 'کسٹم فیس') $$),
  'FORBIDDEN',
  'a subject teacher cannot create a fee head'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── case-insensitive code uniqueness ────────────────────────────────────

select throws_ok(
  format($$ select public.create_fee_head('exam', 'Exam Fee Duplicate', 'نقل') $$),
  'duplicate key value violates unique constraint "fee_head_tenant_code_uq"',
  'a code differing only in case from an existing head (EXAM vs exam) is rejected'
);

-- ── deactivation touches only is_active ─────────────────────────────────

select public.create_fee_head('CUSTOM', 'Custom Fee', 'کسٹم فیس') as custom_id \gset
select public.set_fee_head_active(:'custom_id'::uuid, false);
select is(
  (select is_active from public.fee_head where id = :'custom_id'),
  false,
  'deactivating a fee head flips is_active'
);
select is(
  (select name_en from public.fee_head where id = :'custom_id'),
  'Custom Fee',
  'deactivation does not touch any other column on the head itself'
);

-- ── tenant isolation ────────────────────────────────────────────────────

reset role;
select public.provision_tenant('test-fee-heads-other', 'Other Fee Heads Co', 'owner@otherfeeheadsco.test');
select id as tenant_other from public.tenant where slug = 'test-fee-heads-other' \gset
select id as campus_other from public.campus where tenant_id = :'tenant_other' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_other', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_other'))::text,
  true
);
select is(
  (select count(*)::int from public.fee_head where tenant_id = :'tenant_id'),
  0,
  'a different tenant reads zero of Fee Heads Co''s heads — RLS scopes by tenant'
);

select * from finish();
rollback;
