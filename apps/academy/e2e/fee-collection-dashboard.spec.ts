import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K30: billed, collected, outstanding and efficiency for the month, and a 12-point trend.

test('the owner sees billing against collection for the month', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, challans } = await seedFeesTenant(2, 'collect-e2e');
  const { error } = await owner$.rpc('record_payment', { p_enrolment_id: challans[0]!.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash' });
  expect(error).toBeNull();

  await expect
    .poll(async () => {
      await db.rpc('refresh_fee_collection_metrics');
      const { data } = await owner$.from('v_fee_collection_monthly').select('billed_paisa');
      return data?.length ?? 0;
    })
    .toBeGreaterThan(0);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/dashboard/collection');
  await expect(page.getByTestId('collection-kpis')).toContainText('PKR 17,000');
  await expect(page.getByTestId('kpi-outstanding')).toHaveText('PKR 8,500');
  await expect(page.getByTestId('kpi-efficiency')).toHaveText('50.0%');
  await expect(page.getByTestId('trend-point')).toHaveCount(12);
  await expect(page.getByTestId('collection-as-of')).toContainText('As of');
});
