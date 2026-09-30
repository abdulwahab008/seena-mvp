import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K19 / FR-K20: upload a bank scroll through the real UI, see duplicate
// files refused, reconcile, and resolve an exception.

test('an accountant imports a bank statement once, reconciles it, and resolves a short payment', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, campusId, challans } = await seedFeesTenant(3, 'bank-e2e');
  const [c1, c2, c3] = challans;

  await db.from('campus_bank_account').insert({ campus_id: campusId, bank_name: 'HBL', title: 'E2E Fees', account_no: '9988', iban: 'PK36HABB0000000000009988' });

  const csv = [
    'Date,Customer Ref,Txn ID,Credit',
    `12/08/2026,${c1!.challan_no},TX-A,"8,500.00"`,
    `12/08/2026,${c2!.challan_no},TX-B,"8,000.00"`,
    `12/08/2026,${c3!.challan_no},TX-C,"8,500.00"`,
    '12/08/2026,,TX-D,oops',
  ].join('\n');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/bank-statements');
  await page.waitForLoadState('networkidle');

  // Mapping profile from a sample header.
  await page.locator('#sample').setInputFiles({ name: 'sample.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.locator('#name').fill('HBL_SCROLL_V2');
  await page.locator('#txnDate').selectOption('Date');
  await page.locator('#challanRef').selectOption('Customer Ref');
  await page.locator('#bankRef').selectOption('Txn ID');
  await page.locator('#amount').selectOption('Credit');
  await page.getByRole('button', { name: 'Save and assign profile' }).click();
  await expect(page.getByText('Profile saved and assigned.')).toBeVisible();

  await page.reload();
  await page.locator('#file').setInputFiles({ name: 'scroll.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByRole('button', { name: 'Import statement' }).click();
  await expect(page.getByTestId('upload-message')).toHaveText('Imported: 3 parsed, 1 failed of 4 rows.');

  await page.locator('#file').setInputFiles({ name: 'scroll-again.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByRole('button', { name: 'Import statement' }).click();
  await expect(page.getByTestId('upload-message')).toContainText('duplicate file (sha256 match, imported');

  await page.reload();
  await page.getByTestId('bank-import-row').first().getByRole('link').click();
  await page.getByTestId('reconcile-run').click();
  await expect(page.getByTestId('recon-summary')).toContainText('Matched: 2');
  await expect(page.getByTestId('recon-summary')).toContainText('Unresolved: 1');

  await page.getByTestId('exception-card').getByPlaceholder('Note (required)').fill('Parent paid the pre-due amount late');
  await page.getByTestId('exception-post').click();
  await expect(page.getByText('Payment posted.')).toBeVisible();
  await expect(page.getByTestId('recon-summary')).toContainText('Unresolved: 0');

  await page.getByTestId('close-import').click();
  await expect(page.getByText('Import closed.')).toBeVisible();
});
