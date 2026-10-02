-- pgTAP tests for FR-K14 (append-only fee ledger) and FR-K15 (correction
-- by reversal entry only).
begin;
select plan(12);

select public.provision_tenant('test-fee-ledger-co', 'Fee Ledger Co', 'owner@feeledgerco.test');
select id as tenant_id from public.tenant where slug = 'test-fee-ledger-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Ledger Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset

-- ── FORBIDDEN / validation ───────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.post_ledger_entry(%L, ''charge'', 850000, ''debit'')', :'enrolment_id'),
  'FORBIDDEN',
  'a subject teacher cannot post a ledger entry'
);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.post_ledger_entry(%L, ''charge'', 0, ''debit'')', :'enrolment_id'),
  'AMOUNT_MUST_BE_POSITIVE',
  'a zero-amount entry is rejected'
);

-- ── balance derives from a full scan of the ledger, matching the AC's numbers ──

select public.post_ledger_entry(:'enrolment_id'::uuid, 'charge', 850000::bigint, 'debit', :'tuition_id'::uuid) as charge_id \gset
select public.post_ledger_entry(:'enrolment_id'::uuid, 'concession', 100000::bigint, 'credit', :'tuition_id'::uuid) as concession_id \gset
select public.post_ledger_entry(:'enrolment_id'::uuid, 'payment', 500000::bigint, 'credit') as payment_id \gset
select is(
  public.student_balance(:'enrolment_id'::uuid),
  250000::bigint,
  'balance = charges 850000 - concession 100000 - payment 500000 = 250000 paisa, matching the AC exactly'
);

-- ── the ledger cannot be mutated by anyone, including a superuser session ──

reset role;
select throws_ok(
  format('update public.fee_ledger set amount_paisa = 0 where id = %L', :'charge_id'),
  'FEE_LEDGER_IMMUTABLE',
  'UPDATE on a ledger row is rejected, even outside the authenticated role'
);
select throws_ok(
  format('delete from public.fee_ledger where id = %L', :'charge_id'),
  'FEE_LEDGER_IMMUTABLE',
  'DELETE on a ledger row is rejected'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── reversal: owner-only, reasoned, and nets to zero ─────────────────

select throws_ok(
  format($$ select public.reverse_ledger_entry(%L, 'a perfectly good reason for reversal') $$, :'payment_id'),
  'FORBIDDEN',
  'an accountant cannot reverse a ledger entry — owner only'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.reverse_ledger_entry(%L, 'too short') $$, :'payment_id'),
  'REASON_TOO_SHORT',
  'a reversal reason under 15 characters is rejected'
);

select public.reverse_ledger_entry(:'payment_id'::uuid, 'cheque returned unpaid by MCB 12-08') as reversal_id \gset
select is(
  (select direction::text from public.fee_ledger where id = :'reversal_id'),
  'debit',
  'reversing a credit payment posts an opposite (debit) entry'
);
select is(
  (select reversal_of_id from public.fee_ledger where id = :'reversal_id'),
  :'payment_id'::uuid,
  'the reversal records which entry it reverses'
);
select is(
  public.student_balance(:'enrolment_id'::uuid),
  750000::bigint,
  'reversing the 500000-paisa payment restores the balance to 850000 - 100000 = 750000 — net zero effect from the reversal itself'
);

select throws_ok(
  format($$ select public.reverse_ledger_entry(%L, 'trying to reverse the same entry twice') $$, :'payment_id'),
  'duplicate key value violates unique constraint "fee_ledger_reversal_uq"',
  'the same entry cannot be reversed a second time'
);
select throws_ok(
  format($$ select public.reverse_ledger_entry(%L, 'trying to reverse a reversal itself') $$, :'reversal_id'),
  'CANNOT_REVERSE_A_REVERSAL',
  'a reversal entry cannot itself be reversed'
);

select * from finish();
rollback;
