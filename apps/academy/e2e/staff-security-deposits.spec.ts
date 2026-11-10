import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR sets up a staff security deposit and it stays off the loans list', async ({ page }) => {
  const { owner, mkUser } = await seedHrTenant('deposit-e2e');
  await mkUser('teacher', 'subject_teacher', { staff: {} });
  await signInAs(page, owner.email);

  await page.goto('/payroll/security-deposits');
  await page.waitForLoadState('networkidle');
  const staffValue = await page.getByLabel('Staff member').locator('option', { hasText: 'teacher user' }).getAttribute('value');
  await page.getByLabel('Staff member').selectOption(staffValue!);
  await page.getByLabel('Deposit amount (PKR)').fill('30000');
  await page.getByLabel('Monthly deduction (PKR)').fill('50000');
  await page.getByRole('button', { name: 'Add deposit' }).click();
  await expect(page.getByText('The monthly deduction cannot be more than the deposit')).toBeVisible();

  await page.getByLabel('Monthly deduction (PKR)').fill('5000');
  await page.getByRole('button', { name: 'Add deposit' }).click();
  await expect(page.getByText('Security deposit added. Payroll will deduct it each month.')).toBeVisible();
  const row = page.getByTestId('deposit-row').filter({ hasText: 'teacher user' });
  await expect(row).toContainText('Collecting');
  await expect(row).toContainText('30,000');
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Still to collect');

  await page.goto('/payroll/loans');
  await expect(page.locator('tbody').getByText('teacher user')).toHaveCount(0);
});
