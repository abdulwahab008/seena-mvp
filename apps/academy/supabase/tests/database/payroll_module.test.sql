-- ═══════════════════════════════════════════════════════════════════════
-- pgTAP tests for Module L: Payroll (FR-L01 through FR-L09)
-- ═══════════════════════════════════════════════════════════════════════

begin;
select plan(23);

-- ─── 1. Test fn_evaluate_component ─────────────────────────────────────
select is(
  public.fn_evaluate_component('fixed_paisa', 500000, 0, 10000000, 0, 26, 0, true),
  500000::bigint,
  'Fixed component returns exact value when no absences'
);

select is(
  public.fn_evaluate_component('pct_of_basic', 0, 45.0, 10000000, 0, 26, 0, false),
  4500000::bigint,
  'Percentage of basic (45% of 100,000 PKR = 45,000 PKR)'
);

select is(
  public.fn_evaluate_component('pct_of_basic', 0, 10.0, 10000000, 0, 26, 0, false),
  1000000::bigint,
  'Percentage of basic (10% of 100,000 PKR = 10,000 PKR)'
);

select is(
  public.fn_evaluate_component('fixed_paisa', 260000, 0, 10000000, 0, 26, 13, true),
  130000::bigint,
  'Prorated fixed component halves when half days unpaid (13/26)'
);

-- ─── 2. Test Tax Slab Calculations (TY 2026-27) ─────────────────────────
-- 600,000 PKR annual = 0 tax
select is(
  public.fn_annual_tax_paisa(60000000, '2026-2027'),
  0::bigint,
  'Annual income <= 600,000 PKR is exempt from tax'
);

-- 1,200,000 PKR annual: 5% of excess over 600,000 = 5% of 600,000 = 30,000 PKR = 3,000,000 paisa
select is(
  public.fn_annual_tax_paisa(120000000, '2026-2027'),
  3000000::bigint,
  'Annual income 1,200,000 PKR tax is 30,000 PKR (3,000,000 paisa)'
);

-- Monthly withholding on 100,000 PKR / month (1,200,000 annual) = 30,000 / 12 = 2,500 PKR = 250,000 paisa
select is(
  public.fn_monthly_withholding_paisa(gen_random_uuid(), 10000000, '2026-2027'),
  250000::bigint,
  'Monthly withholding on 100,000 PKR monthly taxable is 2,500 PKR'
);

-- ─── 3. Test IBAN Validation ────────────────────────────────────────────
select is(
  public.fn_validate_iban('PK36MEZN0001234567890123'),
  true,
  'Valid 24-character Pakistani IBAN returns true'
);

select is(
  public.fn_validate_iban('PK36 MEZN 0001 2345 6789 0123'),
  true,
  'Valid Pakistani IBAN with whitespace returns true'
);

select is(
  public.fn_validate_iban('INVALID_IBAN_123'),
  false,
  'Invalid IBAN string returns false'
);

-- ─── 4. Setup Test Fixture for Full Payroll Run ─────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', '11111111-1111-1111-1111-111111111111',
    'app_role', 'owner',
    'campus_ids', json_build_array('22222222-2222-2222-2222-222222222222')
  )::text,
  true
);

do $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
  v_staff_id  uuid;
  v_run_id    uuid;
  v_loan_id   uuid;
  v_rec_cnt   int;
begin
  -- 1. Create tenant and campus
  insert into public.tenant (id, name, slug)
  values ('11111111-1111-1111-1111-111111111111', 'Test School System', 'test-school')
  on conflict (id) do nothing;

  insert into public.campus (id, tenant_id, name, code)
  values ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'Main Campus', 'MC')
  on conflict (id) do nothing;

  -- 2. Create staff member
  insert into public.staff (
    id, tenant_id, campus_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status
  ) values (
    '33333333-3333-3333-3333-333333333333',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    'EMP-001',
    'Muhammad Ali',
    'male',
    'cnic',
    '35201-1234567-1',
    '2026-01-01',
    'active'
  ) on conflict (id) do nothing;

  -- 3. Create active salary structure (Basic = 80,000 PKR = 8,000,000 paisa)
  insert into public.employee_salary_structure (
    tenant_id, campus_id, staff_id, validity, basic_paisa
  ) values (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    daterange('2026-01-01', '2026-12-31', '[]'),
    8000000
  );

  -- 4. Create active loan for staff member (100,000 PKR loan, 10,000 PKR monthly installment)
  insert into public.staff_loan (
    id, tenant_id, campus_id, staff_id, loan_type, principal_paisa, installment_paisa,
    disbursed_at, repayment_start_month, status
  ) values (
    '44444444-4444-4444-4444-444444444444',
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    'loan',
    10000000, -- 100,000 PKR
    1000000,  -- 10,000 PKR / month
    '2026-08-01',
    '2026-08-01',
    'active'
  );
end $$;

-- ─── 5. Test Overlap Exclusion on Salary Structure ───────────────────────
-- Attempting to insert overlapping structure should throw an exclusion violation
prepare duplicate_structure as
  insert into public.employee_salary_structure (
    tenant_id, campus_id, staff_id, validity, basic_paisa
  ) values (
    '11111111-1111-1111-1111-111111111111',
    '22222222-2222-2222-2222-222222222222',
    '33333333-3333-3333-3333-333333333333',
    daterange('2026-06-01', '2027-06-01', '[]'),
    9000000
  );

select throws_ok(
  'duplicate_structure',
  '23P01',
  NULL,
  'Exclusion constraint prevents overlapping salary structures for same employee'
);

-- ─── 6. Test Active Structure Lookup ────────────────────────────────────
select is(
  (select basic_paisa from public.fn_active_salary_structure('33333333-3333-3333-3333-333333333333', '2026-08-15')),
  8000000::bigint,
  'fn_active_salary_structure returns correct active structure'
);

-- ─── 7. Test Attendance Deduction ────────────────────────────────────────
-- Record 2 absent days
insert into public.staff_attendance (
  tenant_id, campus_id, staff_id, att_date, status
) values
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', '2026-08-03', 'absent'),
  ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', '2026-08-04', 'absent');

select is(
  public.fn_unpaid_days('33333333-3333-3333-3333-333333333333', '2026-08-01', '2026-08-31'),
  2.00::numeric,
  'fn_unpaid_days counts 2 absent days correctly'
);

-- 2 days absent with 80,000 PKR basic over 26 days = round(80,000 * 2 / 26) = 6,154 PKR = 615,385 paisa
select is(
  public.fn_attendance_deduction_paisa('33333333-3333-3333-3333-333333333333', 8000000, '2026-08-01', '2026-08-31', 26),
  615385::bigint,
  'Attendance deduction is calculated accurately per payable day basis'
);

-- ─── 8. Test Payroll Run Generation Engine ──────────────────────────────
select lives_ok(
  $$ select public.generate_payroll_run('22222222-2222-2222-2222-222222222222', '2026-08-01') $$,
  'generate_payroll_run executes cleanly'
);

select is(
  (select count(*) from public.payroll_run where campus_id = '22222222-2222-2222-2222-222222222222' and period_month = '2026-08-01')::int,
  1,
  'Payroll run created for the target campus and month'
);

select is(
  (select count(*) from public.payroll_run_line where staff_id = '33333333-3333-3333-3333-333333333333')::int,
  1,
  'Payroll run line created for employee'
);

-- Verify loan recovery occurred automatically
select is(
  (select count(*) from public.staff_loan_recovery where loan_id = '44444444-4444-4444-4444-444444444444')::int,
  1,
  'Loan recovery accrued automatically during payroll run'
);

select is(
  (select total_repaid_paisa from public.staff_loan where id = '44444444-4444-4444-4444-444444444444'),
  1000000::bigint,
  'Staff loan updated with total repaid amount'
);

-- ─── 9. Test Automatic Loan Closing on Full Repayment ────────────────────
insert into public.staff_loan_recovery (
  loan_id, amount_paisa, notes
) values (
  '44444444-4444-4444-4444-444444444444',
  9000000, -- Remaining 90,000 PKR
  'Manual lump sum payoff'
);

select is(
  (select status from public.staff_loan where id = '44444444-4444-4444-4444-444444444444'),
  'closed',
  'Staff loan automatically closed when fully repaid'
);

-- ─── 10. Test Run Locking and Immutability Guard ─────────────────────────
do $$
declare
  v_run_id uuid;
begin
  select id into v_run_id from public.payroll_run
  where campus_id = '22222222-2222-2222-2222-222222222222' and period_month = '2026-08-01';

  perform public.fn_lock_payroll_run(v_run_id);
end $$;

select is(
  (select status from public.payroll_run where campus_id = '22222222-2222-2222-2222-222222222222' and period_month = '2026-08-01'),
  'locked'::public.payroll_run_status,
  'Payroll run transitioned to locked status'
);

-- Attempt to modify a line on a locked run must fail
prepare edit_locked_line as
  update public.payroll_run_line
  set net_paisa = 9999999
  where staff_id = '33333333-3333-3333-3333-333333333333';

select throws_ok(
  'edit_locked_line',
  'P0001',
  NULL,
  'Immutability trigger blocks line modification when payroll run is locked'
);

-- Attempt to regenerate locked run must fail
select throws_ok(
  $$ select public.generate_payroll_run('22222222-2222-2222-2222-222222222222', '2026-08-01') $$,
  'P0001',
  NULL,
  'generate_payroll_run refuses to overwrite an already locked run'
);

select * from finish();
rollback;
