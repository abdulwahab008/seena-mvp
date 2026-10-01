import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R03: register an asset, run a depreciation month (and run it again), then dispose of it at a gain.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('register an asset, depreciate a month idempotently and dispose of it', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(0, 'asset-e2e');

  await signIn(page, email);
  await page.goto('/assets');
  const form = page.getByTestId('asset-form');
  await form.getByLabel('Campus').selectOption({ index: 1 });
  await form.getByLabel('Tag number').fill('IT-0042');
  await form.getByLabel('Name').fill('Projector');
  await form.getByLabel('Category').selectOption('it');
  await form.getByLabel('Purchased on').fill('2026-01-10');
  await form.getByLabel('Capitalised cost (PKR)').fill('120000');
  await form.getByLabel('Useful life (months)').fill('60');
  await page.getByTestId('asset-form-submit').click();
  await expect(page.getByTestId('asset-row')).toHaveCount(1);

  await page.getByLabel('Month (YYYY-MM)').fill('2026-08');
  await page.getByTestId('dep-form-submit').click();
  // 8 months (Jan..Aug) at PKR 2,000 each
  await expect(page.getByTestId('nbv-IT-0042')).toHaveText('PKR 104,000');
  await page.getByTestId('dep-form-submit').click();
  await expect(page.getByTestId('nbv-IT-0042')).toHaveText('PKR 104,000');
  const { count } = await db.from('asset_depreciation_entry').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant);
  expect(count).toBe(8);

  const dispose = page.getByTestId('dispose-form');
  await dispose.getByLabel('Asset').selectOption({ index: 1 });
  await dispose.getByLabel('Disposed on').fill('2026-09-14');
  await dispose.getByLabel('Sale proceeds (PKR)').fill('120000');
  await page.getByTestId('dispose-form-submit').click();
  await expect(page.getByTestId('asset-row')).toContainText('disposed');
  const { data: disposal } = await db.from('asset_disposal').select('nbv_at_disposal, gain_loss').eq('tenant_id', tenant).single();
  expect(Number(disposal!.nbv_at_disposal)).toBe(10200000);
  expect(Number(disposal!.gain_loss)).toBe(1800000);
});
