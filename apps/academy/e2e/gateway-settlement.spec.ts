import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K23: a settlement report is matched to a posted online payment, the commission is recorded
// separately, an unknown transaction becomes an exception, and the same file cannot be imported twice.

test('an accountant imports a gateway settlement file once', async ({ page }) => {
  test.setTimeout(90000);
  const { email, owner$, challans } = await seedFeesTenant(1, 'gwsettle-e2e');
  const txn = `GWE2E-${randomUUID().slice(0, 8)}`;
  const { error } = await owner$.rpc('record_payment', { p_enrolment_id: challans[0]!.enrolment_id, p_amount_paisa: 850000, p_mode: 'online', p_reference_no: txn });
  expect(error).toBeNull();
  const today = new Date().toISOString().slice(0, 10);
  const csv = `Transaction ID,Settlement Date,Gross Amount,Commission,Net Amount\n${txn},${today},"8,500.00",85.00,"8,415.00"\nUNKNOWN-${txn},${today},100.00,1.00,99.00\n`;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/gateway-settlements');
  await page.getByLabel('Gateway').selectOption('jazzcash');
  await page.getByLabel('Settlement report (CSV)').setInputFiles({ name: 'jc.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByTestId('settlement-upload').click();
  await expect(page.getByTestId('settlement-upload-message')).toContainText('2 rows: 1 matched, 1 exceptions, commission PKR 85 recorded');
  await expect(page.getByTestId('settlement-exception')).toHaveCount(1);

  await page.getByLabel('Settlement report (CSV)').setInputFiles({ name: 'jc.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByTestId('settlement-upload').click();
  await expect(page.getByTestId('settlement-upload-message')).toContainText('duplicate file');
});
