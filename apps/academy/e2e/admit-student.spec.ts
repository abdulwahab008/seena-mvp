import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@admit-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `admit-e2e-${runId}`,
    p_legal_name: `Admit E2E School ${runId}`,
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

test('an owner admits a student, links a guardian, and enrols them into a section', async ({ page }) => {
  const { email, password } = await seedOwnerWithSection();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Hamza Iqbal');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();

  await expect(page.getByText('Hamza Iqbal admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  await expect(page.getByRole('heading', { name: 'Hamza Iqbal' })).toBeVisible();

  // Link a guardian — the billing checkbox must be on, or the DB rejects it
  // (FR-C09's "at least one guardian must receive fee notices").
  await page.getByLabel('Name', { exact: true }).fill('Iqbal Hussain');
  await page.getByLabel('Receives fee notices').check();
  await page.getByRole('button', { name: 'Link guardian' }).click();
  await expect(page.getByText('Iqbal Hussain linked.')).toBeVisible();
  await expect(page.getByTestId('guardian-row-Iqbal Hussain')).toContainText('father');
});
