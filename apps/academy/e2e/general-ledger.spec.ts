import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('an accountant sets up the ledger, posts a balanced voucher, reverses it, and the trial balance agrees', async ({ page }) => {
  const { mkUser } = await seedHrTenant('ledger-e2e');
  const accountant = await mkUser('acc', 'accountant');
  await signInAs(page, accountant.email);

  await page.goto('/accounts');
  await page.getByRole('button', { name: 'Set up the standard chart of accounts' }).click();
  await expect(page.getByRole('link', { name: 'Vouchers' })).toBeVisible();

  await page.getByLabel('Narration').fill('October rent paid in cash');
  await page.getByLabel('Account, line 1').selectOption({ label: '5200 · Rent' });
  await page.getByLabel('Debit, line 1').fill('150000');
  await page.getByLabel('Account, line 2').selectOption({ label: '1000 · Cash in hand' });
  await page.getByLabel('Credit, line 2').fill('140000');
  await expect(page.getByRole('button', { name: 'Post voucher' })).toBeDisabled();
  await page.getByLabel('Credit, line 2').fill('150000');
  await page.getByRole('button', { name: 'Post voucher' }).click();
  const entry = page.getByTestId('journal-entry').filter({ hasText: 'October rent paid in cash' });
  await expect(entry).toContainText(/JV-\d{4}-00001/);

  await page.goto('/accounts?tab=trial');
  await expect(page.getByTestId('trial-debits')).toHaveText('PKR 150,000.00');
  await expect(page.getByTestId('trial-credits')).toHaveText('PKR 150,000.00');

  await page.goto('/accounts');
  await entry.getByRole('button', { name: 'Reverse' }).click();
  await page.getByLabel('Reason').fill('Posted to the wrong month');
  await page.getByRole('button', { name: 'Reverse', exact: true }).last().click();
  await expect(entry).toContainText('reversed');
  await page.goto('/accounts?tab=trial');
  await expect(page.getByTestId('trial-row').filter({ hasText: 'Rent' })).toContainText('PKR 0.00');
});
