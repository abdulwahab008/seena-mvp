import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the owner changes expense approval limits and the refund, TC and shop return rules', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(0, 'finance-rules-e2e');
  await signInAs(page, seed.email);

  await page.goto('/settings/finance-rules');
  const bands = page.getByTestId('approval-bands');
  await expect(bands).toContainText('PKR 0 to PKR 25,000: no approval needed');

  const limits = page.getByTestId('approval-limits-form');
  await limits.getByLabel('Campus').selectOption({ index: 1 });
  await limits.getByLabel('No approval needed up to (PKR)').fill('10000');
  await limits.getByLabel('Principal approves up to (PKR); the owner above').fill('50000');
  await page.getByTestId('approval-limits-form-submit').click();
  await expect(bands).toContainText('PKR 0 to PKR 10,000: no approval needed');
  await expect(bands).toContainText('PKR 10,000.01 to PKR 50,000: the principal');
  await expect(bands).toContainText('Above PKR 50,000: the owner');

  await page.getByTestId('settlement-threshold-form').getByLabel('Owner approves above (PKR)').fill('40000');
  await page.getByTestId('settlement-threshold-form-submit').click();
  await expect(page.getByTestId('settlement-threshold')).toContainText('PKR 40,000');

  await page.getByTestId('tc-rule-form').getByLabel('Require no-dues clearance first').selectOption('yes');
  await page.getByTestId('tc-rule-form-submit').click();
  await expect(page.getByTestId('tc-rule')).toHaveText('A TC is issued only after no-dues clearance.');

  await page.getByTestId('return-window-form').getByLabel('Days to return an item').fill('14');
  await page.getByTestId('return-window-form-submit').click();
  await expect(page.getByTestId('return-window')).toContainText('within 14 days');
});
