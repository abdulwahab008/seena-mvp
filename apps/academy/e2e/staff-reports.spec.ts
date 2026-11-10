import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the staff reports hub opens a strength report that counts active staff', async ({ page }) => {
  const { owner, mkUser } = await seedHrTenant('staff-reports-e2e');
  await mkUser('teacher-a', 'subject_teacher', { staff: {} });
  await mkUser('teacher-b', 'subject_teacher', { staff: {} });
  await signInAs(page, owner.email);

  await page.goto('/staff/reports');
  await page.getByTestId('report-row').filter({ hasText: 'Staff strength report' }).getByRole('link', { name: 'View' }).click();
  await expect(page.getByRole('heading', { name: 'Staff strength report' })).toBeVisible();
  const total = page.getByTestId('strength-row').locator('td').nth(4);
  await expect(page.getByTestId('strength-row')).toHaveCount(1);
  await expect(total).toHaveText('2');
});
