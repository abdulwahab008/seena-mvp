-- pgTAP tests for FR-K10: gap-free challan numbering.
--
-- pgTAP runs single-connection, so the AC's own "4,000 challans across 8
-- parallel workers" concurrency claim isn't exercised directly here —
-- only the sequential boundary is (N calls in a row produce N gapless,
-- distinct numbers), which is what the row lock inside next_challan_no()
-- actually protects. Same accepted limitation as every other advisory-
-- lock-protected function tested in this suite.
begin;
select plan(11);

select public.provision_tenant('test-challan-no-co', 'Challan No Co', 'owner@challannoco.test');
select id as tenant_id from public.tenant where slug = 'test-challan-no-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset

-- ── shape: 12 digits, last one is a valid check digit ────────────────

reset role;
select public.next_challan_no(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid) as no1 \gset
select is(
  length(:'no1'),
  12,
  'a challan number is exactly 12 digits'
);
select is(
  public.challan_check_digit(left(:'no1', 11)),
  right(:'no1', 1)::int,
  'the 12th digit is the check digit recomputed from the first 11'
);

-- ── gapless and distinct across repeated calls ───────────────────────

select public.next_challan_no(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid) as no2 \gset
select public.next_challan_no(:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid) as no3 \gset
select is(
  left(:'no1', 11),
  '00000000001',
  'the first challan number for a fresh counter starts at 1'
);
select is(
  left(:'no2', 11),
  '00000000002',
  'the second call is exactly one more — no gap'
);
select is(
  left(:'no3', 11),
  '00000000003',
  'the third call is exactly one more again'
);
select isnt(
  :'no1'::text,
  :'no2'::text,
  'consecutive challan numbers are distinct'
);

-- ── scoped per (tenant, campus, session) — a different session starts fresh ──

select public.provision_tenant('test-challan-no-co-2', 'Challan No Co 2', 'owner@challannoco2.test');
select id as tenant2_id from public.tenant where slug = 'test-challan-no-co-2' \gset
select id as campus2_id from public.campus where tenant_id = :'tenant2_id' \gset
select id as session2_id from public.academic_session where tenant_id = :'tenant2_id' \gset
select public.next_challan_no(:'tenant2_id'::uuid, :'campus2_id'::uuid, :'session2_id'::uuid) as other_no1 \gset
select is(
  left(:'other_no1', 11),
  '00000000001',
  'a different tenant/campus/session has its own counter, starting at 1 again'
);

-- ── service-role only: an authenticated caller cannot call it directly ──

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.next_challan_no(%L, %L, %L)', :'tenant_id', :'campus_id', :'session_id'),
  'permission denied for function next_challan_no',
  'an authenticated user, even an owner, cannot call next_challan_no directly — it is service_role only'
);

-- ── challan_check_digit is a plain, deterministic, broadly callable utility ──

select is(
  public.challan_check_digit('00000000001'),
  public.challan_check_digit('00000000001'),
  'the check digit is deterministic for the same input'
);
select isnt(
  public.challan_check_digit('00000000001'),
  public.challan_check_digit('00000000002'),
  'different bases produce different check digits (for these two inputs)'
);

-- ── a tampered number is detectable — the mechanism the reconciliation
--    exception queue (K19/K20, not built here) would route on ──────────

select isnt(
  public.challan_check_digit(left(:'no1', 11)),
  (right(:'no1', 1)::int + 1) % 10,
  'a corrupted check digit does not match — a scan import can detect this and reject the record'
);

select * from finish();
rollback;
