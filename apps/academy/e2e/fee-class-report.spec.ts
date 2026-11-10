import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('fee reports show class-wise billing and the unpaid balance', async ({ page }) => {
  const { db, email, challans } = await seedFeesTenant(2, 'fee-class-e2e');
  const { data } = await db.from('fee_challan').select('net_paisa, billing_period').in('id', challans.map((c) => c.id));
  const billed = (data ?? []).reduce((t, c) => t + c.net_paisa, 0);
  const from = data![0]!.billing_period.slice(0, 7) + '-01';

  await signInAs(page, email);
  await page.goto(`/fees/class-report?from=${from}`);
  const row = page.getByTestId('class-fee-row').first();
  await expect(row).toBeVisible();
  await expect(row.locator('td').nth(1)).toHaveText('2');
  const pkr = new Intl.NumberFormat('en-PK', { maximumFractionDigits: 0 }).format(billed / 100);
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText(`Still owedPKR ${pkr}`);
  await expect(page.getByTestId('aging-row').first()).toBeVisible();
});
