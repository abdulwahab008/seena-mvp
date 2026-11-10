import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('payroll reports show the monthly trend and one employee salary statement', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, owner, mkUser } = await seedHrTenant('payroll-reports-e2e');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  const { data: run, error } = await db
    .from('payroll_run')
    .insert({ tenant_id, campus_id, period_month: '2026-10-01', status: 'draft', employee_count: 1, total_gross_paisa: 5000000, total_deductions_paisa: 500000, total_net_paisa: 4500000 })
    .select('id')
    .single();
  if (error) throw new Error(error.message);
  const { error: lerr } = await db.from('payroll_run_line').insert({ payroll_run_id: run!.id, staff_id: teacher.staffId!, basic_paisa: 4000000, gross_paisa: 5000000, loan_recovery_paisa: 500000, net_paisa: 4500000 });
  if (lerr) throw new Error(lerr.message);

  await signInAs(page, owner.email);
  await page.goto('/payroll/reports');
  await expect(page.getByTestId('trend-row')).toContainText('Oct 2026');
  await expect(page.getByTestId('trend-row')).toContainText('45,000');
  await page.getByLabel('Staff member').selectOption(teacher.staffId!);
  await page.getByRole('button', { name: 'Show' }).click();
  await expect(page).toHaveURL(/staff=/);
  await expect(page.getByTestId('statement-row')).toContainText('50,000');
  await expect(page.getByTestId('statement-row')).toContainText('5,000');
});
