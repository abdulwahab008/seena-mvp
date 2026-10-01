import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K25: the list, its ageing buckets, the hardship flag and the Excel export.

test('defaulters are bucketed by their oldest unpaid challan and exportable', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, challans } = await seedFeesTenant(2, 'defaulter-e2e');
  const [c1, c2] = challans;
  const daysAgo = (n: number) => new Date(Date.now() - n * 86400_000).toISOString().slice(0, 10);

  await db.from('fee_challan').update({ due_date: daysAgo(65) }).eq('id', c1!.id);
  await db.from('fee_challan').update({ due_date: daysAgo(10) }).eq('id', c2!.id);
  const { error } = await db.rpc('refresh_fee_defaulters');
  expect(error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/defaulters');
  await expect(page.getByTestId('defaulter-row')).toHaveCount(2);
  await expect(page.getByTestId('receivable')).toHaveText('PKR 17,000');
  await expect(page.getByTestId('bucket-totals')).toContainText('61-90 days');

  await page.goto('/fees/defaulters?bucket=61-90');
  await expect(page.getByTestId('defaulter-row')).toHaveCount(1);
  await expect(page.getByTestId('defaulter-row')).toContainText('65');

  await page.getByTestId('export-defaulters').click();
  await expect(page.getByText('contains personal data')).toBeVisible();
  await page.getByTestId('export-reason').fill('Weekly fee follow-up call list for the accounts team');
  await page.getByTestId('export-defaulters').click();
  await expect(page.getByText('Export queued')).toBeVisible();
  const { count } = await db.from('report_export_job').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant).eq('dataset_key', 'fee_defaulters');
  expect(count).toBe(1);
});
