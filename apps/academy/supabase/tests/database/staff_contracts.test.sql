-- pgTAP tests for FR-D04: versioned employment contract records.
begin;
select plan(10);

select public.provision_tenant('test-contract-co', 'Contract Co', 'owner@contractco.test');
select id as tenant_id from public.tenant where slug = 'test-contract-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Contract Teacher', 'female', p_cnic => '4210112340031') as staff_id \gset

-- ── first contract, then a salary revision supersedes it with no gap ──

select public.create_staff_contract(:'staff_id'::uuid, 'permanent', '2026-04-01'::date, p_gross_salary => 80000) as contract1_id \gset
select public.create_staff_contract(:'staff_id'::uuid, 'permanent', '2026-08-01'::date, p_gross_salary => 95000) as contract2_id \gset

select is(
  (select end_date from public.staff_contract where id = :'contract1_id'),
  '2026-07-31'::date,
  'the salary-revision contract closes the original at 2026-07-31 — the day before the new one starts'
);
select is(
  (select start_date from public.staff_contract where id = :'contract2_id'),
  '2026-08-01'::date,
  'the new contract starts exactly where the old one left off — zero gap'
);
select is(
  (select supersedes_id from public.staff_contract where id = :'contract2_id'),
  :'contract1_id'::uuid,
  'the new row records which contract it supersedes'
);

-- ── current_contract resolves the right row for a given date ─────────

select is(
  (public.current_contract(:'staff_id'::uuid, '2026-06-15'::date)).id,
  :'contract1_id'::uuid,
  'a June date resolves to the original (pre-revision) contract'
);
select is(
  (public.current_contract(:'staff_id'::uuid, '2026-09-01'::date)).id,
  :'contract2_id'::uuid,
  'a September date resolves to the revised contract'
);

-- ── overlapping ranges are rejected by the exclusion constraint ──────
-- staff_contract has no INSERT policy for authenticated at all (every
-- write goes through create_staff_contract), so this isolates the
-- constraint's own protection, run as superuser like every other direct-
-- insert exclusion-constraint test in this suite.

reset role;
select throws_ok(
  format(
    $$ insert into public.staff_contract (tenant_id, staff_id, contract_type, start_date, end_date)
       values (%L, %L, 'contract', '2026-05-01', '2026-06-01') $$,
    :'tenant_id', :'staff_id'
  ),
  'conflicting key value violates exclusion constraint "ex_staff_contract_no_overlap"',
  'a directly-inserted range overlapping the first contract is rejected'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── salary is visible to Owner, not to a subject teacher ──────────────

select is(
  (select gross_salary from public.staff_contract_pay where contract_id = :'contract2_id'),
  95000.00,
  'the owner can read the salary'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.staff_contract_pay where contract_id = :'contract2_id'),
  0,
  'a subject teacher reading the same row sees zero rows — pay is not visible to them at all'
);
select is(
  (select count(*)::int from public.staff_contract where id = :'contract2_id'),
  0,
  'a subject teacher cannot see the contract itself either (not owner/hr_manager/principal)'
);

-- ── probation lapsed worklist ──────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_staff(:'campus_id'::uuid, 'Probation Teacher', 'male', p_cnic => '4210112340032') as probation_staff_id \gset
select public.create_staff_contract(:'probation_staff_id'::uuid, 'probation', '2026-01-01'::date) as probation_contract_id \gset
reset role;
update public.staff_contract set end_date = '2026-06-30'::date where id = :'probation_contract_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.fn_flag_probation_lapsed() where id = :'probation_contract_id'),
  1,
  'an unconfirmed probation contract past its end date appears on the lapsed worklist'
);

select * from finish();
rollback;
