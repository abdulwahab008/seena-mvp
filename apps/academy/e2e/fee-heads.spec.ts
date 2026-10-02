import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@fee-heads-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `fee-heads-e2e-${runId}`,
    p_legal_name: `Fee Heads E2E School ${runId}`,
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

test('an owner seeds default fee heads, adds a custom one, and deactivates it', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/heads');
  await page.waitForLoadState('networkidle');

  // FR-K01: seeding gives exactly the 8 defaults, security deposit flagged refundable.
  await page.getByRole('button', { name: 'Seed default fee heads' }).click();
  await expect(page.getByText('Default fee heads seeded.')).toBeVisible();
  await expect(page.getByTestId('fee-head-row-TUITION')).toBeVisible();
  await expect(page.getByTestId('fee-head-row-SECURITY_DEPOSIT')).toContainText('refundable');
  await expect(page.getByTestId('fee-head-row-TUITION')).not.toContainText('refundable');

  // A custom head can be added alongside the defaults.
  await page.getByLabel('Code').fill('LIBRARY');
  await page.getByLabel('Name (English)').fill('Library Fee');
  await page.getByLabel('Name (Urdu)').fill('لائبریری فیس');
  await page.getByRole('button', { name: 'Add fee head' }).click();
  await expect(page.getByText('Library Fee created.')).toBeVisible();
  await expect(page.getByTestId('fee-head-row-LIBRARY')).toBeVisible();

  // Deactivating never deletes — the row stays, marked inactive.
  const libraryRow = page.getByTestId('fee-head-row-LIBRARY');
  await libraryRow.getByRole('button', { name: 'Deactivate' }).click();
  await expect(page.getByText('Fee head deactivated.')).toBeVisible();
  await expect(libraryRow).toContainText('inactive');
  await expect(libraryRow).toContainText('Library Fee');
});

test('a duplicate code differing only in case is rejected', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/heads');
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Seed default fee heads' }).click();
  await expect(page.getByText('Default fee heads seeded.')).toBeVisible();

  await page.getByLabel('Code').fill('tuition');
  await page.getByLabel('Name (English)').fill('Duplicate Tuition');
  await page.getByLabel('Name (Urdu)').fill('نقل');
  await page.getByRole('button', { name: 'Add fee head' }).click();
  await expect(page.getByText('A fee head with code "tuition" already exists.')).toBeVisible();
});
