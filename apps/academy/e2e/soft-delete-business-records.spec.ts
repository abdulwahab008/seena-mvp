import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A15: soft delete of business records, exercised end to end through the
// real UI — delete a student, confirm it's gone from the roster, find it in
// the Owner-only Recycle Bin with deleted_by/deleted_at, restore it, and
// confirm it's back in the roster (AC1, AC2).
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@soft-delete-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `soft-delete-e2e-${runId}`,
    p_legal_name: `Soft Delete E2E School ${runId}`,
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

test('an owner deletes a student, finds them in the Recycle Bin, and restores them into the roster', async ({ page }) => {
  const { email, password } = await seedOwner();
  const studentName = 'Zainab Farooq';

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Female', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill(studentName);
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText(`${studentName} admitted.`)).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  // AC1: delete the student — this is a 10-second, reversible action, not a
  // restore-from-backup incident.
  await page.getByTestId('delete-student-button').click();
  await page.getByTestId('confirm-delete-student').click();
  await expect(page.getByText(`${studentName} moved to the Recycle Bin.`)).toBeVisible();
  await expect(page).toHaveURL(/\/students$/);

  // AC1: gone from the ordinary roster (scoped to the roster link itself —
  // a plain text match would also catch this run's own toast messages).
  await expect(page.getByRole('link', { name: new RegExp(studentName) })).not.toBeVisible();

  // AC2: an Owner opens the Recycle Bin and sees deleted_by/deleted_at plus
  // a Restore action.
  await page.goto('/students/recycle-bin');
  await page.waitForLoadState('networkidle');
  const binRow = page.getByTestId(/^recycle-bin-row-/);
  await expect(binRow).toContainText(studentName);
  await expect(binRow).toContainText('Deleted');
  await expect(binRow).toContainText('E2E Owner');
  await binRow.getByRole('button', { name: 'Restore' }).click();
  await expect(page.getByText(`${studentName} restored.`)).toBeVisible();
  await expect(page.getByText('The Recycle Bin is empty.')).toBeVisible();

  // Restored student reappears in the ordinary roster.
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText(studentName)).toBeVisible();
});
