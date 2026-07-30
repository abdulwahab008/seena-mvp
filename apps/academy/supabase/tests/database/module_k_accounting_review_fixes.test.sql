-- pgTAP tests for the Module K accounting-code independent-review fixes
-- (20260731290000_module_k_accounting_review_fixes.sql).
--
-- Fix #1 (collect_cash_payment()'s idempotency lock) is not exercised
-- here — the actual bug was a race between two genuinely concurrent
-- connections, which a single-connection pgTAP transaction can't
-- simulate, the same limitation already noted for every other
-- advisory-lock claim in this codebase (FR-K10's challan numbering,
-- FR-K16's payment allocation). The existing sequential-replay coverage
-- in cash_counter_receipt.test.sql already proves the lock doesn't
-- change the single-caller behavior; this file only covers fix #2,
-- which is a plain ordering rule fully testable sequentially.
begin;
select plan(3);

select public.provision_tenant('test-cashbook-order-co', 'Cashbook Order Co', 'owner@cashbookorderco.test');
select id as tenant_id from public.tenant where slug = 'test-cashbook-order-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select (current_date - 5) as day1 \gset
select (current_date - 3) as day2 \gset
select (current_date - 1) as day4 \gset

-- Finalise day2 (3 days ago) first, then try day1 (5 days ago, BEHIND
-- the already-finalised day2) — refused, since it would corrupt the
-- running balance chain day2 already established.
select public.finalise_cash_book_day(:'campus_id'::uuid, :'day2'::date);

select throws_ok(
  format('select public.finalise_cash_book_day(%L, %L)', :'campus_id', :'day1'),
  'CANNOT_FINALISE_BEFORE_A_LATER_FINALISED_DAY',
  'finalising an earlier day once a later day is already finalised is refused — it would corrupt the running balance chain'
);

-- Gaps moving FORWARD are still fine: day4 (1 day ago) is AHEAD of the
-- already-finalised day2, skipping the day in between entirely — no
-- ordering rule stands in the way of that.
select public.finalise_cash_book_day(:'campus_id'::uuid, :'day4'::date) as cb_day4 \gset
select is(
  (:'cb_day4'::public.cash_book_day).opening_paisa,
  (select closing_paisa from public.cash_book_day where campus_id = :'campus_id' and book_date = :'day2'),
  'a gap moving forward (skipping the day in between) still correctly carries forward the most recent PRIOR finalised day''s closing'
);

-- The correct chronological order still works end to end: day1 refused
-- above is exactly the scenario the fix targets — confirm the underlying
-- table genuinely has no row for it.
select is(
  (select count(*)::int from public.cash_book_day where campus_id = :'campus_id' and book_date = :'day1'),
  0,
  'the refused out-of-order finalisation never wrote a row at all'
);

select * from finish();
rollback;
