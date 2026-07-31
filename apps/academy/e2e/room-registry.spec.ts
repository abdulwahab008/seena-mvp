import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@room-registry-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `room-registry-e2e-${runId}`,
    p_legal_name: `Room Registry E2E School ${runId}`,
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

test('an owner adds a room, a duplicate code at the same campus is rejected, and deactivating keeps the row', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/rooms');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Code').fill('SL-1');
  await page.getByLabel('Name').fill('Science Lab 1');
  await page.getByTestId('room-type-trigger').click();
  await page.getByRole('option', { name: 'SCIENCE LAB', exact: true }).click();
  await page.getByLabel('Capacity').fill('30');
  await page.getByRole('button', { name: 'Add room' }).click();

  await expect(page.getByText('Science Lab 1 added.')).toBeVisible();
  const row = page.getByTestId('room-row-SL-1');
  await expect(row).toBeVisible();
  await expect(row).toContainText('SCIENCE LAB');
  await expect(row).toContainText('capacity 30');

  // AC: a second room at the same campus with the same code is rejected.
  await page.getByLabel('Code').fill('SL-1');
  await page.getByLabel('Name').fill('Duplicate Lab');
  await page.getByLabel('Capacity').fill('20');
  await page.getByRole('button', { name: 'Add room' }).click();
  await expect(page.getByText('A room coded "SL-1" already exists at this campus.')).toBeVisible();

  // Deactivating never deletes — the row stays, marked inactive.
  await row.getByRole('button', { name: 'Deactivate' }).click();
  await expect(page.getByText('Room deactivated.')).toBeVisible();
  await expect(row).toContainText('inactive');
  await expect(row).toContainText('Science Lab 1');
});
