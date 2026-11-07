import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('payroll sets up provident fund and reads the gratuity owed to staff', async ({ page }) => {
  const { db, tenantId, campusId, mkUser, owner } = await seedHrTenant('pf-gratuity');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: { doj: '2019-01-01' } });
  await db.from('employee_salary_structure').insert({ tenant_id: tenantId, campus_id: campusId, staff_id: teacher.staffId!, validity: '[2020-01-01,)', basic_paisa: 5000000 });
  await signInAs(page, owner.email);

  await page.goto('/payroll/gratuity');
  await page.getByLabel('Employee share (% of basic)').fill('6');
  await page.getByLabel('School share (% of basic)').fill('6');
  await page.getByRole('button', { name: 'Add provident fund' }).click();
  await expect(page.getByTestId('pf-status')).toContainText('6% of basic');

  const years = new Date().getFullYear() - 2019 - (new Date() < new Date(new Date().getFullYear(), 0, 1) ? 1 : 0);
  const row = page.getByTestId('gratuity-row').filter({ hasText: 'teacher user' });
  await expect(row.getByRole('cell').nth(2)).toHaveText(String(years));
  await expect(row.getByRole('cell').nth(4)).toHaveText(`PKR ${(years * 50000).toLocaleString('en-US')}.00`);
});
