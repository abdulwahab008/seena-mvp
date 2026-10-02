import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithFeeHeadsClass1Only() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@structure-ver-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `structure-ver-e2e-${runId}`,
    p_legal_name: `Structure Ver E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { error: e4 } = await admin.from('fee_head').insert({
    tenant_id: tenantId as string,
    code: 'TUITION',
    name_en: 'Tuition Fee',
    name_ur: 'فیس تعلیم',
    is_mandatory: true,
    default_frequency: 'monthly',
  });
  if (e4) throw e4;

  // Only Class 1 stays active — a published structure only needs a
  // mandatory-head line for whichever classes are actually active.
  const { error: e5 } = await admin.from('class_level').update({ is_active: false }).eq('tenant_id', tenantId as string).neq('code', '1');
  if (e5) throw e5;

  // FR-A03: /fees/structure is gated on the onboarding wizard's fee_heads
  // step — see fee-structure.spec.ts's own seeding helper for why this is
  // needed now that provision_tenant() seeds that step as pending.
  const { error: e6 } = await admin
    .from('onboarding_progress')
    .update({ status: 'done' })
    .eq('tenant_id', tenantId as string)
    .eq('step_key', 'fee_heads');
  if (e6) throw e6;

  return { email, password };
}

test('an owner revises a published fee structure into a new version without touching the original', async ({ page }) => {
  const { email, password } = await seedOwnerWithFeeHeadsClass1Only();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/structure');
  await page.waitForLoadState('networkidle');
  await page.getByRole('button', { name: 'Create draft structure' }).click();
  await expect(page.getByText('Draft structure created.')).toBeVisible();

  await page.getByTestId('structure-line-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByTestId('structure-line-head-trigger').click();
  await page.getByRole('option', { name: /Tuition Fee/ }).click();
  await page.getByLabel('Amount (PKR)').fill('5000');
  await page.getByText('Jan', { exact: true }).click();
  await page.getByRole('button', { name: 'Add line' }).click();
  await expect(page.getByText('Line added.')).toBeVisible();

  await page.getByTestId('publish-structure-button').click();
  await expect(page.getByText('Structure published.')).toBeVisible();
  await expect(page.getByTestId('structure-status')).toHaveText('published');

  // Revise: create version 2, effective a year out, and raise the TUITION
  // line from PKR 5,000 to PKR 5,500 — a 10% increase, well under any
  // (unset) cap, so no regulator reference is needed.
  await page.getByLabel('Revise, effective from').fill('2027-01-01');
  await page.getByTestId('create-next-version-button').click();
  await expect(page.getByText('New version created.')).toBeVisible();
  await expect(page.getByTestId('structure-status')).toHaveText('draft');

  await page.getByRole('button', { name: 'Edit' }).click();
  await page.locator('input[type="number"]').last().fill('5500');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Amount updated.')).toBeVisible();
  await expect(page.getByText('PKR 5,500')).toBeVisible();

  await page.getByTestId('publish-structure-button').click();
  await expect(page.getByText('Structure published.')).toBeVisible();
  await expect(page.getByTestId('structure-status')).toHaveText('published');
  await expect(page.getByText('Version 2')).toBeVisible();

  // Version 1 is preserved, untouched, in the history list.
  await expect(page.getByTestId('structure-history-1')).toContainText('superseded');
  await expect(page.getByTestId('structure-history-1')).toContainText('effective');
});
