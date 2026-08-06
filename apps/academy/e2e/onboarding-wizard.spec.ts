import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@onboarding-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `onboarding-e2e-${runId}`,
    p_legal_name: `Onboarding E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { email, password, tenantId: tenantId as string };
}

async function signIn(page: import('@playwright/test').Page, email: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
}

test('a fresh tenant starts the onboarding checklist at 0/7 with every step pending, and login is not gated on it', async ({ page }) => {
  const { email, password } = await seedOwner();

  // FR-A03's own Notes: login must never be gated on onboarding — a fresh
  // owner lands on the normal dashboard, not forced into the wizard.
  await signIn(page, email, password);

  await page.getByRole('link', { name: 'Setup' }).click();
  await expect(page).toHaveURL(/\/onboarding$/);
  await expect(page.getByTestId('onboarding-progress')).toHaveText('0/7 complete');

  for (const key of ['campus_details', 'branding', 'academic_session', 'class_structure', 'fee_heads', 'staff_invitations', 'first_student']) {
    await expect(page.getByTestId(`onboarding-status-${key}`)).toHaveText('Not started');
  }
});

test('an owner applies a class preset, marks a step done and skips another, and progress is resumable across a reload', async ({ page }) => {
  const { email, password } = await seedOwner();
  await signIn(page, email, password);
  await page.goto('/onboarding');
  await page.waitForLoadState('networkidle');

  // AC: picking the "Nursery, KG, 1-10" preset creates 12 class rows with
  // one default section each, and the step is auto-marked done.
  await page.getByTestId('onboarding-apply-preset').click();
  await expect(page.getByText('Class structure applied.')).toBeVisible();
  await expect(page.getByTestId('onboarding-status-class_structure')).toHaveText('Done');
  await expect(page.getByTestId('onboarding-progress')).toHaveText('1/7 complete');

  // AC: steps 1-3 done, closing and resuming (here: a full reload) opens
  // exactly where they left off — steps 1-3 shown complete.
  await page.getByTestId('onboarding-done-campus_details').click();
  await expect(page.getByText('Marked done.')).toBeVisible();
  await expect(page.getByTestId('onboarding-status-campus_details')).toHaveText('Done');

  // AC: skipping fee heads still counts toward the resolved total, and the
  // step is flagged as skipped, not silently dropped.
  await page.getByTestId('onboarding-skip-fee_heads').click();
  await expect(page.getByText('Skipped.')).toBeVisible();
  await expect(page.getByTestId('onboarding-status-fee_heads')).toHaveText('Skipped');

  await expect(page.getByTestId('onboarding-progress')).toHaveText('3/7 complete');

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('onboarding-progress')).toHaveText('3/7 complete');
  await expect(page.getByTestId('onboarding-status-campus_details')).toHaveText('Done');
  await expect(page.getByTestId('onboarding-status-class_structure')).toHaveText('Done');
  await expect(page.getByTestId('onboarding-status-fee_heads')).toHaveText('Skipped');
  await expect(page.getByTestId('onboarding-status-branding')).toHaveText('Not started');
});

test('the Fees module stays blocked until the fee_heads step is actually done, even after it was skipped', async ({ page }) => {
  const { email, password } = await seedOwner();
  await signIn(page, email, password);

  await page.goto('/fees/structure');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Finish the fee heads step in your setup checklist first.')).toBeVisible();

  await page.goto('/onboarding');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('onboarding-skip-fee_heads').click();
  await expect(page.getByText('Skipped.')).toBeVisible();

  // AC: a skipped step still blocks the Fees module — only 'done' lifts it.
  await page.goto('/fees/structure');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Finish the fee heads step in your setup checklist first.')).toBeVisible();

  await page.goto('/fees/heads');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Code').fill('TUITION');
  await page.getByLabel('Name (English)').fill('Tuition Fee');
  await page.getByLabel('Name (Urdu)').fill('فیس تعلیم');
  await page.getByRole('button', { name: 'Add fee head' }).click();
  await expect(page.getByText('Tuition Fee created.')).toBeVisible();

  await page.goto('/onboarding');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('onboarding-done-fee_heads').click();
  await expect(page.getByTestId('onboarding-status-fee_heads')).toHaveText('Done');

  await page.goto('/fees/structure');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Finish the fee heads step in your setup checklist first.')).not.toBeVisible();
});
