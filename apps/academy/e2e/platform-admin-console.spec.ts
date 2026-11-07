import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { seedFreshOwner } from './fixtures/fresh-owner';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const PASSWORD = 'e2e-test-password-123!';

async function seedPlatformAdmin() {
  const admin = createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  const email = `platform-${randomUUID().slice(0, 8)}@e2e.test`;
  const { data, error } = await admin.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
  if (error || !data.user) throw error ?? new Error('user creation failed');
  const { error: insertError } = await admin.from('platform_admin').insert({ user_id: data.user.id });
  if (insertError) throw insertError;
  return email;
}

async function signIn(page: Page, email: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('a platform admin creates a school and suspending a school locks its owner out', async ({ browser }) => {
  const owner = await seedFreshOwner('platform-target');
  const { data: tenant } = await createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } })
    .from('tenant')
    .select('slug')
    .eq('id', owner.tenantId)
    .single();
  const adminEmail = await seedPlatformAdmin();

  const adminPage = await (await browser.newContext()).newPage();
  await signIn(adminPage, adminEmail, PASSWORD);
  await expect(adminPage).toHaveURL(/\/platform$/);
  await expect(adminPage.getByRole('heading', { name: 'Schools' })).toBeVisible();

  const slug = `e2e-new-${randomUUID().slice(0, 8)}`;
  await adminPage.getByLabel('School code').fill(slug);
  await adminPage.getByLabel('Legal / school group name').fill('E2E New School');
  await adminPage.getByLabel('Owner email').fill(`${slug}@e2e.test`);
  await adminPage.getByRole('button', { name: 'Create school' }).click();
  await expect(adminPage.getByTestId('provision-result')).toBeVisible();
  await expect(adminPage.getByTestId(`school-${slug}`)).toContainText('E2E New School');

  const target = adminPage.getByTestId(`school-${tenant!.slug}`);
  await target.getByRole('button', { name: 'Suspend' }).click();
  await adminPage.getByLabel(/Reason/).fill('Invoice unpaid');
  await adminPage.getByTestId('confirm-status').click();
  await expect(target.getByTestId('school-status')).toHaveText('Suspended');

  const ownerPage = await (await browser.newContext()).newPage();
  await signIn(ownerPage, owner.email, owner.password);
  await expect(ownerPage.getByTestId('school-suspended')).toBeVisible();

  await target.getByRole('button', { name: 'Reactivate' }).click();
  await adminPage.getByLabel(/Reason/).fill('Paid');
  await adminPage.getByTestId('confirm-status').click();
  await expect(target.getByTestId('school-status')).toHaveText('Active');
});

test('a school owner cannot open the platform console', async ({ page }) => {
  const owner = await seedFreshOwner('platform-deny');
  await signIn(page, owner.email, owner.password);
  await expect(page).toHaveURL(/\/dashboard$/);
  const response = await page.goto('/platform');
  expect(response?.status()).toBe(404);
});
