import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@room-upgrades-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `room-upgrades-e2e-${runId}`,
    p_legal_name: `Room Upgrades School ${runId}`,
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

test('room management: add rooms, KPI metrics, edit modal, filtering, and search', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/rooms');
  await page.waitForLoadState('networkidle');

  // Verify page header
  await expect(page.getByRole('heading', { name: 'Rooms & Venues' })).toBeVisible();

  // 1. Add Classroom
  await page.getByLabel('Code').fill('CR-101');
  await page.getByLabel('Name').fill('General Classroom 101');
  await page.getByTestId('room-type-trigger').click();
  await page.getByRole('option', { name: 'CLASSROOM', exact: true }).click();
  await page.getByLabel('Capacity').fill('35');
  await page.getByLabel('Block (optional)').fill('Block A');
  await page.getByRole('button', { name: 'Add room' }).click();
  await expect(page.getByText('General Classroom 101 added.')).toBeVisible();

  // 2. Add Science Lab
  await page.getByLabel('Code').fill('SL-PHY');
  await page.getByLabel('Name').fill('Physics Laboratory');
  await page.getByTestId('room-type-trigger').click();
  await page.getByRole('option', { name: 'SCIENCE LAB', exact: true }).click();
  await page.getByLabel('Capacity').fill('25');
  await page.getByLabel('Block (optional)').fill('Science Wing');
  await page.getByRole('button', { name: 'Add room' }).click();
  await expect(page.getByText('Physics Laboratory added.')).toBeVisible();

  // Verify cards exist
  const crRow = page.getByTestId('room-row-CR-101');
  const slRow = page.getByTestId('room-row-SL-PHY');
  await expect(crRow).toBeVisible();
  await expect(slRow).toBeVisible();
  await expect(crRow).toContainText('capacity 35');
  await expect(slRow).toContainText('capacity 25');

  // 3. Edit Room via Edit Modal
  await slRow.getByRole('button', { name: 'Edit' }).click();
  await expect(page.getByRole('heading', { name: 'Edit Room (SL-PHY)' })).toBeVisible();
  await page.getByLabel('Seating Capacity').fill('30');
  await page.getByLabel('Room Name').fill('Advanced Physics Lab');
  await page.getByRole('button', { name: 'Save Changes' }).click();

  await expect(page.getByText('Room "Advanced Physics Lab" updated successfully.')).toBeVisible();
  await expect(slRow).toContainText('Advanced Physics Lab');
  await expect(slRow).toContainText('capacity 30');

  // 4. Test Filter Pills
  // Filter by Science
  await page.getByRole('button', { name: 'Science', exact: true }).click();
  await expect(slRow).toBeVisible();
  await expect(crRow).toBeHidden();

  // Filter by Classrooms
  await page.getByRole('button', { name: 'Classrooms', exact: true }).click();
  await expect(crRow).toBeVisible();
  await expect(slRow).toBeHidden();

  // Reset to All
  await page.getByRole('button', { name: 'All', exact: true }).first().click();
  await expect(crRow).toBeVisible();
  await expect(slRow).toBeVisible();

  // 5. Test Search
  await page.getByPlaceholder('Search by code, name, block...').fill('Advanced');
  await expect(slRow).toBeVisible();
  await expect(crRow).toBeHidden();

  await page.getByPlaceholder('Search by code, name, block...').fill('');
  await expect(crRow).toBeVisible();
  await expect(slRow).toBeVisible();

  // 6. Test Deactivation
  await crRow.getByRole('button', { name: 'Deactivate' }).click();
  await expect(page.getByText('Room deactivated.')).toBeVisible();
  await expect(crRow).toContainText('inactive');

  // Filter by Inactive status
  await page.getByRole('button', { name: 'Inactive' }).click();
  await expect(crRow).toBeVisible();
  await expect(slRow).toBeHidden();

  // Reactivate
  await crRow.getByRole('button', { name: 'Activate' }).click();
  await expect(page.getByText('Room activated.')).toBeVisible();
});
