import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR marks daily staff attendance and the marks are kept', async ({ page }) => {
  const { owner, mkUser, db } = await seedHrTenant('staff-att-e2e');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  await signInAs(page, owner.email);

  await page.goto('/attendance/staff');
  const row = page.getByTestId('staff-attendance-row').filter({ hasText: 'teacher user' });
  await row.getByLabel('Late').check();
  await page.getByRole('button', { name: 'Save attendance' }).click();
  await expect(page.getByText(/Saved attendance for \d+ staff\./)).toBeVisible();
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Late1');
  const { data } = await db.from('staff_attendance').select('status').eq('staff_id', teacher.staffId!);
  expect(data).toEqual([{ status: 'late' }]);
});
