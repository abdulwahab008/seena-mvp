import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithTwoSubmittedApplications() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@merit-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `merit-e2e-${runId}`,
    p_legal_name: `Merit E2E School ${runId}`,
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
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  async function seedApplication(no: string, childName: string, dob: string) {
    const { data: enquiry } = await admin
      .from('admission_enquiry')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: session!.id,
        enquiry_no: no,
        child_name: childName,
        dob,
        class_applied_id: classLevel!.id,
        parent_name: 'Parent',
        phone_e164: `+92300${no.slice(-7)}`,
        whatsapp_opt_in: false,
        source: 'walk_in',
        status: 'converted',
      })
      .select('id')
      .single();
    const { error } = await admin.from('admission_application').insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_id: enquiry!.id,
      application_no: `APP-${no}`,
      class_applied_id: classLevel!.id,
      status: 'submitted',
    });
    if (error) throw error;
  }

  await seedApplication('MERIT-0000001', 'Merit One', '2020-01-01');
  await seedApplication('MERIT-0000002', 'Merit Two', '2020-01-01');

  return { email, password };
}

test('an owner records subject-wise scores, sees the merit rank, publishes it, and a locked sitting refuses corrections', async ({
  page,
}) => {
  const { email, password } = await seedOwnerWithTwoSubmittedApplications();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/admissions/test-sittings');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('sitting-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.locator('#startsAt').fill('2026-08-10T09:00');
  await page.locator('#venue').fill('Score hall');
  await page.locator('#capacity').fill('5');
  await page.getByRole('button', { name: 'Schedule sitting' }).click();
  await expect(page.getByText('Test sitting scheduled.')).toBeVisible();

  const sittingRow = page.locator('[data-testid^="sitting-row-"]').filter({ hasText: 'Score hall' });
  await expect(sittingRow).toBeVisible();

  await sittingRow.locator('[data-testid^="allocate-app-trigger-"]').click();
  await page.getByRole('option', { name: /Merit One/ }).click();
  await sittingRow.getByRole('button', { name: 'Allocate seat' }).click();
  await expect(page.getByText('Allocated seat 1.')).toBeVisible();

  await sittingRow.locator('[data-testid^="allocate-app-trigger-"]').click();
  await page.getByRole('option', { name: /Merit Two/ }).click();
  await sittingRow.getByRole('button', { name: 'Allocate seat' }).click();
  await expect(page.getByText('Allocated seat 2.')).toBeVisible();

  const candidateRows = sittingRow.locator('[data-testid^="candidate-row-"]');
  await expect(candidateRows).toHaveCount(2);

  async function saveScore(row: ReturnType<typeof candidateRows.nth>, subject: string, obtained: string, total: string) {
    await row.locator('[data-testid^="score-subject-"]').fill(subject);
    await row.locator('[data-testid^="score-obtained-"]').fill(obtained);
    await row.locator('[data-testid^="score-total-"]').fill(total);
    await row.locator('[data-testid^="score-save-"]').click();
    await expect(page.getByText('Score saved.')).toBeVisible();
  }

  const row1 = candidateRows.filter({ hasText: 'Merit One' });
  const row2 = candidateRows.filter({ hasText: 'Merit Two' });

  await saveScore(row1, 'math', '45', '50');
  await saveScore(row2, 'math', '30', '50');

  // AC: the merit rank and its tie-break basis are visible per candidate.
  await expect(row1.locator('[data-testid^="candidate-rank-"]')).toContainText('Rank 1');
  await expect(row2.locator('[data-testid^="candidate-rank-"]')).toContainText('Rank 2');

  // AC: obtained cannot exceed total — the client-side schema catches it
  // before the request is even sent.
  await row1.locator('[data-testid^="score-subject-"]').fill('english');
  await row1.locator('[data-testid^="score-obtained-"]').fill('999');
  await row1.locator('[data-testid^="score-total-"]').fill('50');
  await row1.locator('[data-testid^="score-save-"]').click();
  await expect(page.getByText('Obtained cannot exceed total')).toBeVisible();

  // AC: publishing locks the sitting and the score-entry controls disappear.
  await sittingRow.getByRole('button', { name: 'Publish merit list' }).click();
  await expect(page.getByText('Merit list published.')).toBeVisible();
  await expect(sittingRow.locator('[data-testid^="sitting-lock-status-"]')).toHaveText('Published (locked)');
  await expect(row1.locator('[data-testid^="score-subject-"]')).toHaveCount(0);

  // A Principal (here, the owner, who is also allowed) unlocks it again.
  await sittingRow.getByRole('button', { name: 'Unlock' }).click();
  await expect(page.getByText('Sitting unlocked.')).toBeVisible();
  await expect(sittingRow.locator('[data-testid^="sitting-lock-status-"]')).toHaveText('Not published');
});
