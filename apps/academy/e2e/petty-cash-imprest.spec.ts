import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-L12: spend from the tin, hit the cap, count it, and have the Principal top it back up to the float.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('a counted replenishment restores the float after Principal sign-off', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId } = await seedFeesTenant(0, 'petty-e2e');
  const principalEmail = `principal-${tenant.slice(0, 8)}@petty-e2e.test`;
  const { data: principal } = await db.auth.admin.createUser({ email: principalEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: principal.user!.id, tenant_id: tenant, app_role: 'principal', full_name: 'Seed Principal' });
  await db.from('user_campus').insert({ user_id: principal.user!.id, tenant_id: tenant, campus_id: campusId });

  await signIn(page, email);
  await page.goto('/expenses/petty-cash');
  await page.getByLabel('Float (PKR)').fill('10000');
  await page.getByLabel('Per-payment cap (PKR)').fill('5000');
  await page.getByTestId('petty-create').click();
  await expect(page.getByTestId('petty-balance')).toHaveText('PKR 10,000');

  await page.getByLabel('Amount (PKR)').fill('5000');
  await page.getByTestId('petty-pay').click();
  await expect(page.getByTestId('petty-balance')).toHaveText('PKR 5,000');

  await page.getByLabel('Amount (PKR)').fill('7000');
  await page.getByTestId('petty-pay').click();
  await expect(page).toHaveURL(/\/expenses\/vouchers/);

  await page.goto('/expenses/petty-cash');
  await page.getByLabel('Cash counted in the tin (PKR)').fill('4500');
  await page.getByLabel(/Explanation if the count differs/).fill('Short by five hundred rupees, checking receipts');
  await page.getByTestId('petty-replenish').click();
  await expect(page.getByTestId('petty-pending')).toContainText('variance PKR -500');

  const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const page2 = await ctx.newPage();
  await signIn(page2, principalEmail);
  await page2.goto('/expenses/petty-cash');
  await page2.getByTestId('petty-approve').click();
  await expect(page2.getByTestId('petty-balance')).toHaveText('PKR 10,000');
  await ctx.close();
});
