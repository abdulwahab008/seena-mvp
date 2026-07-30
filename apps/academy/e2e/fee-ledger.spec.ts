import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@fee-ledger-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `fee-ledger-e2e-${runId}`,
    p_legal_name: `Fee Ledger E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 5,
  });
  if (e4) throw e4;

  return { email, password };
}

test('posting and reversing ledger entries keeps the balance correct throughout', async ({ page }) => {
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
  await page.getByRole('option', { name: 'Female', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Ledger E2E Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // Post a charge: balance goes to 5,000.
  await page.getByTestId('ledger-entry-type-trigger').click();
  await page.getByRole('option', { name: 'charge' }).click();
  await page.getByTestId('ledger-direction-trigger').click();
  await page.getByRole('option', { name: 'debit', exact: true }).click();
  await page.locator('#ledger-amount').fill('5000');
  await page.getByRole('button', { name: 'Post entry' }).click();
  await expect(page.getByText('Entry posted.')).toBeVisible();
  await expect(page.getByTestId('ledger-balance')).toHaveText('Balance: PKR 5,000');

  // Post a payment: balance goes to 0.
  await page.getByTestId('ledger-entry-type-trigger').click();
  await page.getByRole('option', { name: 'payment' }).click();
  await page.getByTestId('ledger-direction-trigger').click();
  await page.getByRole('option', { name: 'credit', exact: true }).click();
  await page.locator('#ledger-amount').fill('5000');
  await page.getByRole('button', { name: 'Post entry' }).click();
  await expect(page.getByText('Entry posted.')).toBeVisible();
  await expect(page.getByTestId('ledger-balance')).toHaveText('Balance: PKR 0');

  // Reverse the payment: balance goes back to 5,000 — the append-only
  // ledger's only correction path, never an edit or delete.
  const paymentRow = page.locator('[data-testid^="ledger-row-"]').filter({ hasText: 'payment' });
  await paymentRow.getByRole('button', { name: 'Reverse' }).click();
  await paymentRow.getByPlaceholder('Reason (15+ chars)').fill('cheque returned unpaid by the bank');
  await paymentRow.getByRole('button', { name: 'Confirm' }).click();
  await expect(page.getByText('Entry reversed.')).toBeVisible();
  await expect(page.getByTestId('ledger-balance')).toHaveText('Balance: PKR 5,000');
});
