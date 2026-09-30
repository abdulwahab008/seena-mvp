import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@batch-rooms.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `batch-rooms-${runId}`,
    p_legal_name: `Batch Rooms School ${runId}`,
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

test('batch classroom generation for Class 10 (Jinnah, Iqbal, Fatima) and standard facilities preset', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/rooms');
  await page.waitForLoadState('networkidle');

  // 1. Switch to "Batch Classrooms" tab
  await page.getByRole('button', { name: 'Batch Classrooms' }).click();
  await expect(page.getByText('Batch Classroom Generator (Multi-Section)')).toBeVisible();

  // 2. Use quick preset "Jinnah, Iqbal, Fatima"
  await page.getByRole('button', { name: 'Jinnah, Iqbal, Fatima' }).click();
  await page.getByLabel('Default Capacity per Room').fill('38');
  await page.getByLabel('Building Block / Wing').fill('Quaid Block');

  // 3. Click Generate Classrooms button
  await page.getByRole('button', { name: /Generate 3 Classrooms/i }).click();

  // Verify success toast
  await expect(page.getByText(/Successfully generated 3 classrooms/i)).toBeVisible();

  // 4. Verify the generated rooms appear in the list
  await expect(page.getByTestId('room-row-10-JINN')).toBeVisible();
  await expect(page.getByTestId('room-row-10-IQBA')).toBeVisible();
  await expect(page.getByTestId('room-row-10-FATI')).toBeVisible();
  await expect(page.getByTestId('room-row-10-JINN')).toContainText('capacity 38');
  await expect(page.getByTestId('room-row-10-JINN')).toContainText('Quaid Block');

  // 5. Test "Standard Labs" preset
  await page.getByRole('button', { name: 'Standard Labs' }).click();
  await expect(page.getByText('Standard Campus Facilities Preset')).toBeVisible();

  // Click Seed 7 Standard Facilities
  await page.getByRole('button', { name: 'Seed 7 Standard Facilities' }).click();
  await expect(page.getByText(/Standard facilities generated/i)).toBeVisible();

  // Verify facilities exist in room list
  await expect(page.getByTestId('room-row-SL-PHY')).toBeVisible();
  await expect(page.getByTestId('room-row-SL-CHM')).toBeVisible();
  await expect(page.getByTestId('room-row-CL-1')).toBeVisible();
  await expect(page.getByTestId('room-row-LIB-1')).toBeVisible();
});
