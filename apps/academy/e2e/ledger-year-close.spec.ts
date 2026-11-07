import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';
import { todayPk } from './support/today';

test('an accountant enters opening balances, closes the last financial year, and the closed year is locked', async ({ page }) => {
  const { mkUser } = await seedHrTenant('ledger-close-e2e');
  const accountant = await mkUser('acc', 'accountant');
  await signInAs(page, accountant.email);

  const today = todayPk();
  const fyStartYear = Number(today.slice(5, 7)) >= 7 ? Number(today.slice(0, 4)) : Number(today.slice(0, 4)) - 1;
  const yearEnd = `${fyStartYear}-06-30`;
  const inClosedYear = `${fyStartYear}-03-10`;

  await page.goto('/accounts');
  await page.getByRole('button', { name: 'Set up the standard chart of accounts' }).click();

  await page.goto('/accounts?tab=year');
  await page.getByLabel('As of').fill(`${fyStartYear - 1}-07-01`);
  await page.getByLabel('1000 · Cash in hand').fill('500');
  await page.getByLabel('2000 · Accounts payable').fill('200');
  await page.getByRole('button', { name: 'Post opening balances' }).click();
  await expect(page.getByText('Opening balances posted.')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Post opening balances' })).toHaveCount(0);

  await page.goto('/accounts');
  await page.getByLabel('Date').fill(inClosedYear);
  await page.getByLabel('Narration').fill('March fees');
  await page.getByLabel('Account, line 1').selectOption({ label: '1000 · Cash in hand' });
  await page.getByLabel('Debit, line 1').fill('1000');
  await page.getByLabel('Account, line 2').selectOption({ label: '4000 · Tuition fee income' });
  await page.getByLabel('Credit, line 2').fill('1000');
  await page.getByRole('button', { name: 'Post voucher' }).click();
  await expect(page.getByTestId('journal-entry').filter({ hasText: 'March fees' })).toBeVisible();

  await page.goto('/accounts?tab=year');
  await expect(page.getByLabel('Year end')).toHaveValue(yearEnd);
  await page.getByRole('button', { name: 'Close year' }).click();
  await page.getByRole('button', { name: 'Close the year' }).click();
  await expect(page.getByText('Year closed.')).toBeVisible();
  await expect(page.getByTestId('locked-through')).toContainText('Books are closed through');

  await page.goto(`/accounts?tab=trial&asOf=${yearEnd}`);
  await expect(page.getByTestId('trial-row').filter({ hasText: 'Retained earnings' })).toContainText('PKR 1,000.00');
  await expect(page.getByTestId('trial-row').filter({ hasText: 'Tuition fee income' }).getByRole('cell').last()).toHaveText('PKR 0.00');

  await page.goto('/accounts');
  await page.getByLabel('Date').fill(inClosedYear);
  await page.getByLabel('Narration').fill('Late March bill');
  await page.getByLabel('Account, line 1').selectOption({ label: '5100 · Utilities' });
  await page.getByLabel('Debit, line 1').fill('10');
  await page.getByLabel('Account, line 2').selectOption({ label: '1000 · Cash in hand' });
  await page.getByLabel('Credit, line 2').fill('10');
  await page.getByRole('button', { name: 'Post voucher' }).click();
  await expect(page.getByText('That date is in a closed year.')).toBeVisible();
});
