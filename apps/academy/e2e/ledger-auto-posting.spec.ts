import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

test('fees post to the ledger on their own, past fees are backfilled once, and the statements agree', async ({ page }) => {
  const { owner$, email, challans } = await seedFeesTenant(2, 'ledger-post');
  const [first, second] = challans;

  // Collected before the school opened Accounts.
  const early = await owner$.rpc('record_payment', { p_enrolment_id: first!.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash', p_reference_no: 'early' });
  expect(early.error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/accounts');
  await page.getByRole('button', { name: 'Set up the standard chart of accounts' }).click();
  await page.getByRole('button', { name: 'Post past records' }).click();
  await expect(page.getByText('Posted 1 past record.')).toBeVisible();
  await expect(page.getByTestId('journal-entry').filter({ hasText: 'Fee received · early' })).toContainText('auto');
  await page.getByRole('button', { name: 'Post past records' }).click();
  await expect(page.getByText('Everything is already posted.')).toBeVisible();

  await page.goto('/accounts?tab=mapping');
  await page.getByLabel('Account for Tuition Fee').selectOption({ label: '4900 · Other income' });
  await expect(page.getByText('Tuition Fee saved.')).toBeVisible();

  // Collected after: posts by itself, to the account chosen for the head.
  const later = await owner$.rpc('record_payment', { p_enrolment_id: second!.enrolment_id, p_amount_paisa: 850000, p_mode: 'bank_challan', p_reference_no: 'later' });
  expect(later.error).toBeNull();
  await page.goto('/accounts');
  const laterEntry = page.getByTestId('journal-entry').filter({ hasText: 'Fee received · later' });
  await expect(laterEntry).toContainText('Dr 1010 Bank');
  await expect(laterEntry).toContainText('Cr 4900 Other income');

  await page.goto('/accounts?tab=income');
  await expect(page.getByTestId('income-total')).toHaveText('PKR 17,000.00');
  await expect(page.getByTestId('period-surplus')).toHaveText('PKR 17,000.00');

  await page.goto('/accounts?tab=balance');
  await expect(page.getByTestId('assets-total')).toHaveText('PKR 17,000.00');
  await expect(page.getByTestId('equity-total')).toHaveText('PKR 17,000.00');
  await expect(page.getByText('does not balance')).toHaveCount(0);
});
