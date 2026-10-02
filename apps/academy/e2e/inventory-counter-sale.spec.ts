import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R02: sell 2 shirts and a book for cash (PKR 3,050, serial receipt with GR/name/class), then charge a shirt to fee.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('a counter sale prints a serial receipt and a charge-to-fee sale lands on the fee ledger', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'sale-e2e');
  const { data: student } = await db.from('student').select('id, gr_number, name_en').eq('tenant_id', tenant).single();
  const { data: shirt } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'SHIRT-26', name: 'School shirt', category: 'uniform', size: '26', sale_price: 120000 }).select('id').single();
  const { data: book } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'BOOK-ENG1', name: 'English book 1', category: 'textbook', sale_price: 65000 }).select('id').single();
  const { data: store, error: storeError } = await owner$.rpc('create_inv_store', { p_campus_id: campusId, p_name: 'Main Store' });
  expect(storeError).toBeNull();
  for (const item of [shirt!.id, book!.id]) {
    const { error } = await owner$.rpc('post_stock_movement', { p_store_id: store as string, p_item_id: item, p_type: 'receipt', p_qty: 20 });
    expect(error).toBeNull();
  }

  await signIn(page, email);
  await page.goto(`/inventory/sales?gr=${student!.gr_number}`);
  await expect(page.getByTestId('sale-student')).toContainText(student!.name_en);
  await page.getByLabel('Quantity of SHIRT-26').fill('2');
  await page.getByLabel('Quantity of BOOK-ENG1').fill('1');
  await expect(page.getByTestId('sale-total')).toContainText('3,050');
  await page.getByTestId('sale-submit').click();

  await expect(page).toHaveURL(/\/inventory\/sales\/[0-9a-f-]{36}$/);
  await expect(page.getByTestId('receipt-total')).toContainText('PKR 3,050');
  await expect(page.getByTestId('receipt-serial')).toHaveText(/^UNI-\d{4}-\d{5}$/);
  await expect(page.getByTestId('receipt-student')).toContainText(`GR ${student!.gr_number}`);
  await expect(page.getByTestId('receipt-student')).toContainText(student!.name_en);

  await page.goto(`/inventory/sales?gr=${student!.gr_number}`);
  await page.getByLabel('Quantity of SHIRT-26').fill('1');
  await page.getByLabel('Settlement').selectOption('fee_ledger');
  await page.getByTestId('sale-submit').click();
  await expect(page).toHaveURL(/\/inventory\/sales\/[0-9a-f-]{36}$/);

  const { data: ledger } = await db.from('fee_ledger').select('amount_paisa, direction').eq('tenant_id', tenant).eq('source_type', 'inv_sale');
  expect(ledger).toEqual([{ amount_paisa: 120000, direction: 'debit' }]);
  const { data: sales } = await db.from('inv_sale').select('serial').eq('tenant_id', tenant).order('serial');
  expect(sales).toHaveLength(2);
});
