import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R05: log a repair with downtime and a capital improvement; the asset ledger shows cost, maintenance and NBV together.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('maintenance is logged against the asset, capital repairs raise its cost and downtime blocks availability', async ({ page }) => {
  test.setTimeout(120000);
  const { owner$, db, email, tenant, campusId } = await seedFeesTenant(0, 'maint-e2e');
  const { data: assetId, error } = await owner$.rpc('create_asset', {
    p_campus_id: campusId, p_tag_no: 'GEN-01', p_name: 'Generator', p_category: 'other', p_purchased_on: '2026-01-10', p_capitalised_cost: 12000000, p_useful_life_months: 60,
  });
  expect(error).toBeNull();

  await signIn(page, email);
  await page.goto('/assets/maintenance');
  const form = page.getByTestId('maintenance-form');
  await form.getByLabel('Asset').selectOption({ index: 1 });
  await form.getByLabel('Fault or work done').fill('Replace alternator');
  await form.getByLabel('Cost (PKR)').fill('18500');
  await form.getByLabel('Downtime from').fill('2026-08-04');
  await form.getByLabel('Downtime to').fill('2026-08-09');
  await form.getByLabel('Next service due').fill('2026-09-01');
  await page.getByTestId('maintenance-form-submit').click();
  await expect(page.getByTestId('repair-row')).toHaveCount(1);

  // a capital improvement below the threshold is refused
  await form.getByLabel('Asset').selectOption({ index: 1 });
  await form.getByLabel('Fault or work done').fill('New control panel');
  await form.getByLabel('Cost (PKR)').fill('30000');
  await form.getByLabel(/Capital improvement/).check();
  await page.getByTestId('maintenance-form-submit').click();
  await expect(page.getByTestId('maintenance-form-error')).toContainText('capitalisation threshold');

  await form.getByLabel('Cost (PKR)').fill('65000');
  await page.getByTestId('maintenance-form-submit').click();
  await expect(page.getByTestId('repair-row')).toHaveCount(2);

  await page.goto(`/assets/${assetId as string}`);
  await expect(page.getByTestId('ledger-cost')).toHaveText('PKR 185,000');
  await expect(page.getByTestId('ledger-maintenance')).toHaveText('PKR 18,500');

  const { error: blocked } = await owner$.rpc('assert_asset_available', { p_asset_id: assetId as string, p_on: '2026-08-06' });
  expect(blocked?.message).toContain('ASSET_IN_REPAIR');
  const { count } = await db.from('asset_maintenance').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant);
  expect(count).toBe(2);
});
