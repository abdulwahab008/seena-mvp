import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R01: set up a store and an item, receive 200 shirts, count 198, and see the on-hand follow the ledger.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('receive stock, take a physical count and see on-hand follow the immutable ledger', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(0, 'inv-e2e');

  await signIn(page, email);
  await page.goto('/inventory');
  await expect(page.getByTestId('no-store')).toBeVisible();

  await page.getByTestId('store-form').getByLabel('Campus').selectOption({ index: 1 });
  await page.getByTestId('store-form-submit').click();
  await expect(page.getByTestId('store-card')).toHaveCount(1);

  const item = page.getByTestId('item-form');
  await item.getByLabel('Item code').fill('SHIRT-26');
  await item.getByLabel('Name').fill('School shirt');
  await item.getByLabel('Category').selectOption('uniform');
  await item.getByLabel('Size (uniforms)').fill('26');
  await item.getByLabel('Sale price (PKR)').fill('1200');
  await page.getByTestId('item-form-submit').click();
  await expect(page.getByTestId('stock-row')).toHaveCount(1);

  const receipt = page.getByTestId('receipt-form');
  await receipt.getByLabel('Store').selectOption({ index: 1 });
  await receipt.getByLabel('Item').selectOption({ index: 1 });
  await receipt.getByLabel('Quantity').fill('200');
  await page.getByTestId('receipt-form-submit').click();
  await expect(page.getByTestId('on-hand-SHIRT-26')).toHaveText('200');

  const take = page.getByTestId('take-form');
  await take.getByLabel('Store').selectOption({ index: 1 });
  await take.getByLabel('Item').selectOption({ index: 1 });
  await take.getByLabel('Counted quantity').fill('198');
  await take.getByLabel('Reason').selectOption('SHRINKAGE');
  await page.getByTestId('take-form-submit').click();
  await expect(page.getByTestId('on-hand-SHIRT-26')).toHaveText('198');

  const { data: rows } = await db.from('inv_stock_movement').select('movement_type, qty, reason_code').eq('tenant_id', tenant).order('moved_at');
  expect(rows).toHaveLength(2);
  expect(rows!.map((r) => Number(r.qty))).toEqual([200, -2]);
  expect(rows![1]?.reason_code).toBe('SHRINKAGE');
});
