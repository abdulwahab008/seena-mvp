import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithFeeHeads() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@fee-structure-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `fee-structure-e2e-${runId}`,
    p_legal_name: `Fee Structure E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // Seeded directly (not via seed_default_fee_heads's RPC), the same way
  // other e2e specs seed prerequisite data: its own FORBIDDEN check reads
  // JWT claims a service-role call never carries.
  const { error: e4 } = await admin.from('fee_head').insert({
    tenant_id: tenantId as string,
    code: 'TUITION',
    name_en: 'Tuition Fee',
    name_ur: 'فیس تعلیم',
    is_mandatory: true,
    default_frequency: 'monthly',
  });
  if (e4) throw e4;

  // FR-A03: /fees/structure is gated on the onboarding wizard's fee_heads
  // step — this test's tenant has a fee head (seeded directly above, not
  // through the wizard), so mark the step done the same way completing it
  // via the wizard would, otherwise the page shows the blocking empty
  // state instead of the structure UI this test exercises.
  const { error: e5 } = await admin
    .from('onboarding_progress')
    .update({ status: 'done' })
    .eq('tenant_id', tenantId as string)
    .eq('step_key', 'fee_heads');
  if (e5) throw e5;

  return { email, password };
}

test('an owner drafts a fee structure line and publishing is blocked by mandatory-head coverage', async ({ page }) => {
  const { email, password } = await seedOwnerWithFeeHeads();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/fees/structure');
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Create draft structure' }).click();
  await expect(page.getByText('Draft structure created.')).toBeVisible();
  await expect(page.getByTestId('structure-status')).toHaveText('draft');

  // Add a TUITION line for Class 1 only — the default seed covers 14
  // classes (Nursery..12), so this deliberately leaves every other class
  // without a mandatory TUITION line.
  await page.getByTestId('structure-line-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByTestId('structure-line-head-trigger').click();
  await page.getByRole('option', { name: /Tuition Fee/ }).click();
  await page.getByLabel('Amount (PKR)').fill('5000');
  await page.getByText('Jan', { exact: true }).click();
  await page.getByRole('button', { name: 'Add line' }).click();
  await expect(page.getByText('Line added.')).toBeVisible();
  await expect(page.getByText('Class 1 · Tuition Fee')).toBeVisible();
  await expect(page.getByText('PKR 5,000')).toBeVisible();

  // Every other active class is still missing its mandatory TUITION line.
  await page.getByTestId('publish-structure-button').click();
  await expect(
    page.getByText('Every active class needs a line for each mandatory fee head before this structure can publish.')
  ).toBeVisible();
  await expect(page.getByTestId('structure-status')).toHaveText('draft');
});
