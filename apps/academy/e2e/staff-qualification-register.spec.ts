import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndTeacher() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@qual-e2e.test`;
  const teacherEmail = `teacher-${runId}@qual-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `qual-e2e-${runId}`,
    p_legal_name: `Qualification E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Chemistry Teacher' });
  if (e5) throw e5;

  return { ownerEmail, password };
}

test('an owner records two qualifications for a teacher, then verifies one and rejects the other', async ({ page }) => {
  const { ownerEmail, password } = await seedOwnerAndTeacher();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/staff/qualifications');
  await page.waitForLoadState('networkidle');

  // AC1: an MSc Chemistry (2014) and a BEd (2016) — both save independently.
  await page.getByTestId('qualification-staff-trigger').click();
  await page.getByRole('option', { name: 'Chemistry Teacher' }).click();
  await page.getByTestId('qualification-level-trigger').click();
  await page.getByRole('option', { name: 'master', exact: true }).click();
  await page.getByTestId('qualification-discipline-input').fill('Chemistry');
  await page.getByTestId('qualification-institution-input').fill('University of the Punjab');
  await page.getByTestId('qualification-year-input').fill('2014');
  await page.getByRole('button', { name: 'Add qualification' }).click();
  await expect(page.getByText('Qualification saved.').last()).toBeVisible();

  await page.getByTestId('qualification-staff-trigger').click();
  await page.getByRole('option', { name: 'Chemistry Teacher' }).click();
  await page.getByTestId('qualification-level-trigger').click();
  await page.getByRole('option', { name: 'bachelor', exact: true }).click();
  await page.getByTestId('qualification-discipline-input').fill('Education');
  await page.getByTestId('qualification-institution-input').fill('Allama Iqbal Open University');
  await page.getByTestId('qualification-year-input').fill('2016');
  await page.getByRole('button', { name: 'Add qualification' }).click();
  await expect(page.getByText('Qualification saved.').last()).toBeVisible();

  const mscRow = page.locator('[data-testid^="qualification-row-"]').filter({ hasText: 'Chemistry' }).filter({ hasText: 'master' });
  const bedRow = page.locator('[data-testid^="qualification-row-"]').filter({ hasText: 'Education' }).filter({ hasText: 'bachelor' });
  await expect(mscRow).toContainText('pending');
  await expect(bedRow).toContainText('pending');

  // AC2/HR decision: the owner (HR-tier) verifies the MSc and rejects the BEd.
  await mscRow.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByText('Qualification verified.')).toBeVisible();
  await expect(mscRow).toContainText('verified');
  // A decided row no longer offers Verify/Reject.
  await expect(mscRow.getByRole('button', { name: 'Verify' })).toHaveCount(0);

  await bedRow.getByRole('button', { name: 'Reject' }).click();
  await expect(page.getByText('Qualification rejected.')).toBeVisible();
  await expect(bedRow).toContainText('rejected');
});
