import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the stock movement report lists receipts and write-offs and filters by movement', async ({ page }) => {
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'stock-moves-e2e');
  const { data: item } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'COPY-1', name: 'Exercise copy', category: 'stationery', uom: 'pcs', reorder_level: 0, sale_price: 5000 }).select('id').single();
  const { data: store } = await owner$.rpc('create_inv_store', { p_campus_id: campusId, p_name: 'Main Store' });
  expect((await owner$.rpc('post_stock_movement', { p_store_id: store as string, p_item_id: item!.id, p_type: 'receipt', p_qty: 50, p_unit_cost: 4000 })).error).toBeNull();
  expect((await owner$.rpc('post_stock_movement', { p_store_id: store as string, p_item_id: item!.id, p_type: 'writeoff', p_qty: -3, p_reason_code: 'DAMAGE' })).error).toBeNull();

  await signInAs(page, email);
  await page.goto('/inventory/movements');
  await expect(page.getByTestId('movement-row')).toHaveCount(2);
  await expect(page.getByTestId('movement-row').filter({ hasText: 'Received' })).toContainText('40');
  await page.getByLabel('Movement').selectOption('writeoff');
  await page.getByRole('main').getByRole('button', { name: 'Show' }).click();
  await expect(page).toHaveURL(/type=writeoff/);
  await expect(page.getByTestId('movement-row')).toHaveCount(1);
  await expect(page.getByTestId('movement-row')).toContainText('-3 pcs');
});
