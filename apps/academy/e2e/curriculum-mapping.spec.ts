import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSubject() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@curriculum-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `curriculum-e2e-${runId}`,
    p_legal_name: `Curriculum E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // Seeded directly (not via create_subject's RPC), the same way other e2e
  // specs seed prerequisite data: create_subject's own FORBIDDEN check reads
  // JWT claims that a service-role call never carries.
  const { error: e4 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'MATH', name_en: 'Mathematics', name_ur: 'ریاضی' });
  if (e4) throw e4;

  return { email, password };
}

test('an owner maps a subject onto class 9 and sees the weekly-period total update', async ({ page }) => {
  const { email, password } = await seedOwnerWithSubject();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/curriculum');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('curriculum-class-trigger').click();
  await page.getByRole('option', { name: 'Class 9', exact: true }).click();

  await page.getByTestId('curriculum-subject-trigger').click();
  await page.getByRole('option', { name: 'Mathematics', exact: true }).click();
  await page.getByLabel('Weekly periods').fill('6');
  await page.getByRole('button', { name: 'Map subject' }).click();

  await expect(page.getByText('Mathematics mapped.')).toBeVisible();
  const row = page.getByTestId('curriculum-row-Mathematics');
  await expect(row).toBeVisible();
  await expect(row).toContainText('6');
  await expect(row).toContainText('Compulsory');
  await expect(page.getByTestId('curriculum-total')).toHaveText('Total weekly periods: 6 / 40');
});

test('submitting with no subject chosen shows a field error instead of silently doing nothing', async ({ page }) => {
  const { email, password } = await seedOwnerWithSubject();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/curriculum');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('curriculum-class-trigger').click();
  await page.getByRole('option', { name: 'Class 9', exact: true }).click();

  // No subject chosen, but weekly periods filled — previously this
  // silently failed react-hook-form's internal validation with no visible
  // feedback at all (AC: curriculum-mapper-silent-required-field-failure).
  await page.getByLabel('Weekly periods').fill('6');
  await page.getByRole('button', { name: 'Map subject' }).click();

  await expect(page.getByText('Choose a subject')).toBeVisible();
  await expect(page.getByTestId('curriculum-row-Mathematics')).not.toBeVisible();
});

test('weekly periods over 12 is rejected with a visible error, not silently saved', async ({ page }) => {
  const { email, password } = await seedOwnerWithSubject();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/curriculum');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('curriculum-class-trigger').click();
  await page.getByRole('option', { name: 'Class 9', exact: true }).click();

  await page.getByTestId('curriculum-subject-trigger').click();
  await page.getByRole('option', { name: 'Mathematics', exact: true }).click();
  // The old HTML max=12 was silently unenforceable (the form has
  // noValidate), and the server only rejected 0/negative — 15 used to
  // save successfully with no feedback at all.
  await page.getByLabel('Weekly periods').fill('15');
  await page.getByRole('button', { name: 'Map subject' }).click();

  await expect(page.getByText('Must be at most 12')).toBeVisible();
  await expect(page.getByTestId('curriculum-row-Mathematics')).not.toBeVisible();
});
