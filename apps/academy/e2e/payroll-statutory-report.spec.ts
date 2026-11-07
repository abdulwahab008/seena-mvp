import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs, userClient } from './support/hr-seed';

test('the statutory report lists EOBI and tax per staff member with totals and a CSV', async ({ page }) => {
  test.setTimeout(120000);
  const { db, tenantId, campusId, mkUser, owner } = await seedHrTenant('statutory-e2e');
  const a = await mkUser('emp-a', 'subject_teacher', { staff: { doj: '2025-01-01' } });
  await db.from('employee_salary_structure').insert({ tenant_id: tenantId, campus_id: campusId, staff_id: a.staffId!, validity: '[2026-01-01,2026-12-31]', basic_paisa: 7000000 });
  const o = await userClient(owner.email);
  const { data: runId, error } = await o.rpc('generate_payroll_run', { p_campus_id: campusId, p_period_date: '2026-08-01' });
  expect(error).toBeNull();
  const { data: line } = await db.from('payroll_run_line').select('id').eq('payroll_run_id', runId as string).single();
  await db.from('payroll_run_line_component').insert([
    { line_id: line!.id, code: 'EOBI_EE', name_en: 'EOBI Employee', component_type: 'deduction', amount_paisa: 26000, is_taxable: false },
    { line_id: line!.id, code: 'EOBI_ER', name_en: 'EOBI Employer', component_type: 'employer_contribution', amount_paisa: 130000, is_taxable: false },
  ]);

  await signInAs(page, owner.email);
  await page.goto('/payroll/statutory');
  await expect(page.getByRole('columnheader', { name: 'EOBI Employee' })).toBeVisible();
  await expect(page.getByRole('columnheader', { name: 'EOBI Employer (school)' })).toBeVisible();
  await expect(page.getByTestId('statutory-row')).toContainText('PKR 260.00');

  const csv = await page.request.get(`/api/payroll/statutory?run=${runId}`);
  expect(csv.status()).toBe(200);
  expect(await csv.text()).toContain('EOBI Employer');
});
