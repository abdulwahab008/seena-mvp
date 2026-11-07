import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the sales report totals counter sales by item and payment', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'salesreport');
  const { data: student } = await db.from('student').select('gr_number').eq('tenant_id', tenant).single();
  const { data: juice } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'JUICE', name: 'Juice box', category: 'consumable', sale_price: 5000 }).select('id').single();
  const { data: store } = await owner$.rpc('create_inv_store', { p_campus_id: campusId, p_name: 'Canteen' });
  await owner$.rpc('post_stock_movement', { p_store_id: store as string, p_item_id: juice!.id, p_type: 'receipt', p_qty: 50 });

  await signInAs(page, email);
  await page.goto(`/inventory/sales?gr=${student!.gr_number}`);
  await page.getByLabel('Quantity of JUICE').fill('3');
  await page.getByTestId('sale-submit').click();
  await expect(page).toHaveURL(/\/inventory\/sales\/[0-9a-f-]{36}$/);

  await page.goto('/inventory/sales-report');
  await expect(page.getByTestId('sales-item').filter({ hasText: 'Juice box' })).toContainText('PKR 150.00');
  await expect(page.getByTestId('sales-summary')).toContainText('PKR 150.00');
});
