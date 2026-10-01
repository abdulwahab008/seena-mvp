import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-N12: Urdu toggle flips the portal to RTL, persists across devices, and keeps Latin numerals.

test('Urdu preference flips the portal to RTL, persists on another device, keeps Latin amounts', async ({ browser }) => {
  test.setTimeout(90000);
  const { db, tenant, challans } = await seedFeesTenant(1, 'lang-e2e');
  const challan = challans[0]!;
  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challan.enrolment_id).single();
  const email = `parent-${randomUUID().slice(0, 8)}@lang-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Lang Parent', phone_e164: '+923001239999', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  async function signIn(page: import('@playwright/test').Page) {
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Password').fill(SEED_PASSWORD);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL(/\/portal/);
  }

  const deviceA = await browser.newContext({ viewport: { width: 360, height: 780 } });
  const a = await deviceA.newPage();
  await signIn(a);
  await a.goto('/portal/fees');
  await expect(a.getByRole('heading', { name: 'Fee Dues & Billing' })).toBeVisible();
  await expect(a.locator('[dir="ltr"]').first()).toBeVisible();

  await a.getByTestId('language-toggle').click();
  await expect(a.getByRole('heading', { name: 'فیس واجبات اور بلنگ' })).toBeVisible();
  await expect(a.locator('[dir="rtl"][lang="ur"]')).toBeVisible();
  await expect(a.getByTestId(`balance-${challan.challan_no}`)).toHaveText('PKR 8,500');
  await expect(a.getByText('Challan #' + challan.challan_no)).toBeVisible();
  const overflow = await a.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  expect(overflow).toBeLessThanOrEqual(0);

  // A different device: logs in fresh and gets Urdu without re-selecting it.
  const deviceB = await browser.newContext();
  const b = await deviceB.newPage();
  await signIn(b);
  await b.goto('/portal/fees');
  await expect(b.getByRole('heading', { name: 'فیس واجبات اور بلنگ' })).toBeVisible();

  // And back to English.
  await b.getByTestId('language-toggle').click();
  await expect(b.getByRole('heading', { name: 'Fee Dues & Billing' })).toBeVisible();
  await deviceA.close();
  await deviceB.close();
});
