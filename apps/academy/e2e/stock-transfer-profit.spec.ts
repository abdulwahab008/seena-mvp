import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('stock moves between two stores and the shop profit report nets revenue against cost', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(1, 'inv-transfer');
  const { data: item } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'SHIRT-26', name: 'School shirt', category: 'uniform', uom: 'pcs', reorder_level: 0, sale_price: 150000 }).select('id').single();
  const { data: main } = await db.from('inv_store').insert({ tenant_id: tenant, campus_id: campusId, name: 'Main Store' }).select('id').single();
  const { data: shop } = await db.from('inv_store').insert({ tenant_id: tenant, campus_id: campusId, name: 'Shop Counter' }).select('id').single();
  const rec = await db.from('inv_stock_movement').insert({ tenant_id: tenant, campus_id: campusId, store_id: main!.id, item_id: item!.id, movement_type: 'receipt', qty: 100, unit_cost: 100000 });
  expect(rec.error).toBeNull();

  await signInAs(page, email);
  await page.goto('/inventory');
  const form = page.getByTestId('transfer-form');
  await form.getByLabel('From store').selectOption(main!.id);
  await form.getByLabel('To store').selectOption(shop!.id);
  await form.getByLabel('Item').selectOption({ index: 1 });
  await form.getByLabel('Quantity').fill('30');
  await page.getByTestId('transfer-form-submit').click();
  await expect(page.getByTestId('store-card').filter({ hasText: 'Shop Counter' }).getByTestId('on-hand-SHIRT-26')).toHaveText('30');
  await expect(page.getByTestId('store-card').filter({ hasText: 'Main Store' }).getByTestId('on-hand-SHIRT-26')).toHaveText('70');

  const { data: enrol } = await db.from('enrolment').select('student_id, student(gr_number, name_en)').eq('id', challans[0]!.enrolment_id).single();
  const st = (Array.isArray(enrol!.student) ? enrol!.student[0] : enrol!.student) as { gr_number: string; name_en: string };
  const { data: sale } = await db.from('inv_sale').insert({ tenant_id: tenant, campus_id: campusId, store_id: shop!.id, serial: 'S-1', financial_year: 2026, student_id: enrol!.student_id, student_gr: st.gr_number, student_name: st.name_en, settlement: 'cash', total: 750000 }).select('id').single();
  await db.from('inv_sale_line').insert({ tenant_id: tenant, sale_id: sale!.id, item_id: item!.id, qty: 5, unit_price: 150000, amount: 750000 });

  await page.goto('/inventory/profit');
  await expect(page.getByTestId('profit-row')).toContainText('PKR 7,500.00');
  await expect(page.getByTestId('profit-total')).toHaveText('PKR 2,500.00');
});
