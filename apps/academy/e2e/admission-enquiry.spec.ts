import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@enquiry-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `enquiry-e2e-${runId}`,
    p_legal_name: `Enquiry E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { email, password };
}

test('an owner records a walk-in enquiry and sees it listed with a generated enquiry number', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');

  // Campus/session default to the tenant's only one; class level needs an
  // explicit pick.
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();

  await page.getByLabel("Child's name").fill('Ayesha Malik');
  await page.getByLabel('Date of birth').fill('2019-05-10');
  await page.getByLabel('Parent/guardian name').fill('Malik Sahab');
  await page.getByLabel('Phone').fill('0300-1234567');
  // Source already defaults to "walk in" — no referrer needed.

  await page.getByRole('button', { name: 'Record enquiry' }).click();

  await expect(page.getByText('Enquiry recorded for Ayesha Malik.')).toBeVisible();
  const row = page.locator('[data-testid^="enquiry-row-MAIN-"]');
  await expect(row).toBeVisible();
  await expect(row).toContainText('Ayesha Malik');
  await expect(row).toContainText('+923001234567');
});
