import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R06: a PKR 250,000 requisition goes Principal then Director, becomes a PO, and a short delivery of 92 of 100 chairs leaves it partially fulfilled.

test('requisition approval chain, purchase order and a short goods receipt', async ({ page, browser, baseURL }) => {
  test.setTimeout(180000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'purchase-e2e');

  const mk = async (suffix: string, role: string) => {
    const mail = `${suffix}-${tenant.slice(0, 8)}@purchase-e2e.test`;
    const { data } = await db.auth.admin.createUser({ email: mail, password: SEED_PASSWORD, email_confirm: true });
    await db.from('app_user').insert({ user_id: data.user!.id, tenant_id: tenant, app_role: role, full_name: `${suffix} user` });
    await db.from('user_campus').insert({ user_id: data.user!.id, tenant_id: tenant, campus_id: campusId });
    return mail;
  };
  const hod = await mk('hod', 'head_of_department');
  const principal = await mk('principal', 'principal');

  const { error: itemError } = await owner$.rpc('create_inv_item', { p_item_code: 'CHAIR', p_name: 'Classroom chair', p_category: 'consumable' });
  expect(itemError).toBeNull();
  const { error: storeError } = await owner$.rpc('create_inv_store', { p_campus_id: campusId, p_name: 'Main Store' });
  expect(storeError).toBeNull();
  const { error: vendorError } = await owner$.rpc('create_procurement_vendor', { p_name: 'Chair Traders' });
  expect(vendorError).toBeNull();

  const signIn = async (p: import('@playwright/test').Page, mail: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(mail);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await expect(p).toHaveURL(/\/dashboard$/);
  };

  // the Owner sets the thresholds: Principal up to 50,000, Director above
  await signIn(page, email);
  await page.goto('/purchasing');
  await page.getByTestId('threshold-save').click();
  await expect(page.getByTestId('threshold-error')).toHaveCount(0);

  // the HOD raises and submits PKR 250,000
  const hodCtx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const hodPage = await hodCtx.newPage();
  await signIn(hodPage, hod);
  await hodPage.goto('/purchasing');
  const form = hodPage.getByTestId('requisition-form');
  await form.getByLabel('Justification').fill('Replace broken classroom chairs');
  await form.getByLabel('Item 1').selectOption({ label: 'CHAIR · Classroom chair' });
  await form.getByLabel('Quantity 1').fill('100');
  await form.getByLabel('Unit cost 1 (PKR)').fill('2500');
  await expect(hodPage.getByTestId('req-estimate')).toContainText('250,000');
  await hodPage.getByTestId('req-save').click();
  await expect(hodPage).toHaveURL(/\/purchasing\/[0-9a-f-]{36}$/);
  const reqUrl = hodPage.url();
  await hodPage.getByTestId('req-submit').click();
  await expect(hodPage.getByTestId('approval-chain')).toContainText('Principal');
  await expect(hodPage.getByTestId('approval-chain')).toContainText('Director');
  await hodCtx.close();

  // the Principal approves first
  const pCtx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pPage = await pCtx.newPage();
  await signIn(pPage, principal);
  await pPage.goto(reqUrl);
  await pPage.getByTestId('req-approve').click();
  await expect(pPage.getByTestId('approval-chain')).toContainText('approved by principal user');
  await pCtx.close();

  // the Director approves, converts to a PO, and receives 92 of 100
  await page.goto(reqUrl);
  await page.getByTestId('req-approve').click();
  await expect(page.getByTestId('req-status')).toHaveText('approved');
  await page.getByTestId('po-form').getByLabel('Vendor').selectOption({ label: 'Chair Traders' });
  await page.getByTestId('po-form-submit').click();
  await page.goto('/purchasing/orders');
  await expect(page.getByTestId('po-card')).toHaveCount(1);
  await page.getByLabel('Received Classroom chair').fill('92');
  await page.getByTestId('receipt-submit').click();
  await expect(page.getByTestId('po-status')).toHaveText('partially fulfilled');
  await expect(page.getByTestId('po-shortfall')).toContainText('short by 8');

  const { data: stock } = await db.from('v_stock_on_hand').select('on_hand').eq('tenant_id', tenant).single();
  expect(Number(stock!.on_hand)).toBe(92);
});
