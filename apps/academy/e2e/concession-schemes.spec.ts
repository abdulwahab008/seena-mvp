import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithFeeHeads() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@concession-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `concession-e2e-${runId}`,
    p_legal_name: `Concession E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // Supabase's bulk insert sends one column list for the whole batch — a
  // key present on one row and omitted on another is sent as an explicit
  // null for the row that omitted it, not "use the column default", so
  // every row spells out every column here.
  const { error: e4 } = await admin.from('fee_head').insert([
    { tenant_id: tenantId as string, code: 'TUITION', name_en: 'Tuition Fee', name_ur: 'فیس تعلیم', is_mandatory: true },
    { tenant_id: tenantId as string, code: 'TRANSPORT', name_en: 'Transport Fee', name_ur: 'ٹرانسپورٹ فیس', is_mandatory: false },
  ]);
  if (e4) throw e4;

  return { email, password };
}

test('an owner creates a concession scheme scoped to one fee head and deactivates it', async ({ page }) => {
  const { email, password } = await seedOwnerWithFeeHeads();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/concessions');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Code').fill('SIBLING2');
  await page.getByLabel('Name (English)').fill('Sibling 2nd Child');
  await page.getByLabel('Name (Urdu)').fill('دوسرا بہن بھائی');
  await page.getByLabel('Value (% or PKR)').fill('10');
  await page.getByLabel('Tuition Fee').check();
  await page.getByRole('button', { name: 'Add scheme' }).click();

  await expect(page.getByText('Sibling 2nd Child created.')).toBeVisible();
  const schemeRow = page.getByTestId('scheme-row-SIBLING2');
  await expect(schemeRow).toBeVisible();
  await expect(schemeRow).toContainText('10% off Tuition Fee');
  // Applicability is per fee head — TRANSPORT was never checked, so it
  // must not appear in the scope, matching FR-K05's own AC.
  await expect(schemeRow).not.toContainText('Transport Fee');

  await schemeRow.getByRole('button', { name: 'Deactivate' }).click();
  await expect(page.getByText('Scheme deactivated.')).toBeVisible();
  await expect(schemeRow).toContainText('inactive');
  await expect(schemeRow).toContainText('Sibling 2nd Child');
});
