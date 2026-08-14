import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithTuitionHead() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@sibling-disc-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `sibling-disc-e2e-${runId}`,
    p_legal_name: `Sibling Disc E2E School ${runId}`,
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

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  const { error: e5 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 10,
  });
  if (e5) throw e5;

  return { email, password };
}

test('an owner maps a sibling rank to a scheme, and the scan proposes a draft award for the younger sibling', async ({ page }) => {
  const { email, password } = await seedOwnerWithTuitionHead();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Create the sibling-discount scheme.
  await page.goto('/fees/concessions');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Code').fill('SIB2ND');
  await page.getByLabel('Name (English)').fill('Sibling 2nd Child');
  await page.getByLabel('Name (Urdu)').fill('دوسرا بہن بھائی');
  await page.getByLabel('Value (% or PKR)').fill('10');
  await page.getByText('Tuition Fee', { exact: true }).click();
  await page.getByRole('button', { name: 'Add scheme' }).click();
  await expect(page.getByText('Sibling 2nd Child created.')).toBeVisible();

  // Map rank 2 to that scheme.
  await page.goto('/fees/sibling-discounts');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('rank-scheme-trigger').click();
  await page.getByRole('option', { name: 'Sibling 2nd Child' }).click();
  await page.getByTestId('save-rank-scheme-button').click();
  await expect(page.getByText('Rank mapping saved.')).toBeVisible();
  await expect(page.getByTestId('rank-row-2')).toContainText('Sibling 2nd Child');

  // Admit two siblings sharing the same father CNIC.
  const cnic = '35202-1111111-1';
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Elder Sibling');
  await page.getByLabel('Date of birth').fill('2012-01-01');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  await page.getByLabel('Name', { exact: true }).fill('Shared Father');
  await page.getByLabel('CNIC (optional)').fill(cnic);
  await page.getByTestId('guardian-relationship-trigger').click();
  await page.getByRole('option', { name: 'father', exact: true }).click();
  await page.getByLabel('Receives fee notices').check();
  await page.getByRole('button', { name: 'Link guardian' }).click();
  await expect(page.getByText('Shared Father linked.')).toBeVisible();
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Female', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Younger Sibling');
  await page.getByLabel('Date of birth').fill('2014-01-01');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  await page.getByLabel('Name', { exact: true }).fill('Shared Father');
  await page.getByLabel('CNIC (optional)').fill(cnic);
  await page.getByTestId('guardian-relationship-trigger').click();
  await page.getByRole('option', { name: 'father', exact: true }).click();
  await page.getByLabel('Receives fee notices').check();
  await page.getByRole('button', { name: 'Link guardian' }).click();
  await expect(page.getByText('Shared Father linked.')).toBeVisible();
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // Run the scan: one group, one proposal (the younger sibling, rank 2).
  await page.goto('/fees/sibling-discounts');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('run-sibling-scan-button').click();
  await expect(page.getByText('Scan complete.')).toBeVisible();
  await expect(page.getByTestId('sibling-scan-result')).toHaveText('Groups found: 1 · Proposals created: 1 · Needs review: 0');
});
