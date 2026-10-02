-- pgTAP tests for FR-K05: concession scheme catalogue.
begin;
select plan(10);

select public.provision_tenant('test-concession-co', 'Concession Co', 'owner@concessionco.test');
select id as tenant_id from public.tenant where slug = 'test-concession-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

-- ── FORBIDDEN: only owner/super_admin manage the catalogue ─────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_concession_scheme('SIBLING2', 'Sibling 2nd Child', 'دوسرا بہن بھائی', 'percentage', 10, %L) $$,
    array[:'tuition_id']::uuid[]
  ),
  'FORBIDDEN',
  'an accountant cannot create a concession scheme — owner/super_admin only'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── applicable heads must exist in this tenant ──────────────────────────

select throws_ok(
  format(
    $$ select public.create_concession_scheme('BOGUS', 'Bogus', 'باطل', 'percentage', 10, %L) $$,
    array[gen_random_uuid()]::uuid[]
  ),
  'FEE_HEAD_NOT_FOUND',
  'a scheme cannot reference a fee head that does not exist in this tenant'
);

-- ── value range: percentage capped at 100 ───────────────────────────────

select throws_ok(
  format(
    $$ select public.create_concession_scheme('OVER100', 'Over 100', 'زیادہ', 'percentage', 150, %L) $$,
    array[:'tuition_id']::uuid[]
  ),
  'new row for relation "concession_scheme" violates check constraint "ck_concession_value_range"',
  'a percentage scheme over 100 is rejected by the check constraint'
);

-- ── applicable_head_ids must be non-empty ───────────────────────────────

select throws_ok(
  $$ select public.create_concession_scheme('NOHEADS', 'No Heads', 'کوئی نہیں', 'percentage', 10, array[]::uuid[]) $$,
  'new row for relation "concession_scheme" violates check constraint "ck_concession_applicable_heads_not_empty"',
  'a scheme with zero applicable heads is rejected'
);

-- ── successful creation, applicable to TUITION only ─────────────────────

select public.create_concession_scheme(
  'SIBLING2', 'Sibling 2nd Child', 'دوسرا بہن بھائی', 'percentage', 10, array[:'tuition_id']::uuid[]
) as scheme_id \gset
select is(
  (select applicable_head_ids from public.concession_scheme where id = :'scheme_id'),
  array[:'tuition_id']::uuid[],
  'the scheme is scoped to exactly the given fee heads — TUITION only, not every head'
);

-- ── case-insensitive code uniqueness ────────────────────────────────────

select throws_ok(
  format(
    $$ select public.create_concession_scheme('sibling2', 'Duplicate', 'نقل', 'percentage', 5, %L) $$,
    array[:'tuition_id']::uuid[]
  ),
  'duplicate key value violates unique constraint "concession_scheme_tenant_code_uq"',
  'a code differing only in case (SIBLING2 vs sibling2) is rejected'
);

-- ── deactivation flips is_active, never deletes ─────────────────────────

select public.set_concession_scheme_active(:'scheme_id'::uuid, false);
select is(
  (select is_active from public.concession_scheme where id = :'scheme_id'),
  false,
  'deactivating a scheme flips is_active'
);
select is(
  (select name_en from public.concession_scheme where id = :'scheme_id'),
  'Sibling 2nd Child',
  'the scheme row itself is never deleted — only new awards are blocked from selecting it'
);

-- ── fixed_amount schemes are exempt from the 0-100 percentage cap ──────

select public.create_concession_scheme(
  'HARDSHIP', 'Hardship Award', 'مالی مشکلات', 'fixed_amount', 150000, array[:'tuition_id']::uuid[]
) as hardship_id \gset
select is(
  (select value from public.concession_scheme where id = :'hardship_id'),
  150000.00,
  'a fixed_amount scheme''s value is not capped at 100 — it is a paisa amount, not a percentage'
);

select throws_ok(
  format(
    $$ select public.create_concession_scheme('NEGVAL', 'Negative', 'منفی', 'fixed_amount', -100, %L) $$,
    array[:'tuition_id']::uuid[]
  ),
  'new row for relation "concession_scheme" violates check constraint "ck_concession_value_range"',
  'a negative value is rejected regardless of calc_type'
);

select * from finish();
rollback;
