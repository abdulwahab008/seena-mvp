import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a shop sale charged to the fee account shows as due until paid', async ({ page }) => {
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'shop-dues-e2e');
  const { data: student } = await db.from('student').select('id, name_en').eq('tenant_id', tenant).single();
  const { data: shirt } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'SHIRT-28', name: 'School shirt', category: 'uniform', size: '28', sale_price: 120000 }).select('id').single();
  const { data: store } = await owner$.rpc('create_inv_store', { p_campus_id: campusId, p_name: 'Main Store' });
  expect((await owner$.rpc('post_stock_movement', { p_store_id: store as string, p_item_id: shirt!.id, p_type: 'receipt', p_qty: 5 })).error).toBeNull();
  const sale = await owner$.rpc('create_sale', { p_student_id: student!.id, p_settlement: 'fee_ledger', p_lines: [{ item_id: shirt!.id, qty: 1, from_package: false }] });
  expect(sale.error).toBeNull();

  await signInAs(page, email);
  await page.goto('/inventory/dues');
  await expect(page.getByTestId('shop-due-row')).toHaveCount(1);
  await expect(page.getByTestId('shop-due-row')).toContainText(student!.name_en);
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Amount duePKR 1,200');
});
