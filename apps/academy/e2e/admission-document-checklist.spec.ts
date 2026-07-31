import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@checklist-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `checklist-e2e-${runId}`,
    p_legal_name: `Checklist E2E School ${runId}`,
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

test('an owner configures a document requirement, and a submitted application is checked against it', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/admissions/checklist');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('doc-type-trigger').click();
  await page.getByRole('option', { name: 'passport photo', exact: true }).click();
  await page.getByTestId('doc-min-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByTestId('doc-max-class-trigger').click();
  await page.getByRole('option', { name: 'Class 12', exact: true }).click();
  await page.locator('#minCount').fill('2');
  await page.getByRole('button', { name: 'Save requirement' }).click();
  await expect(page.getByText('Requirement saved.')).toBeVisible();

  const reqRow = page.getByTestId('requirement-row-passport_photo');
  await expect(reqRow).toBeVisible();
  await expect(reqRow).toContainText('Mandatory');
  await expect(reqRow).toContainText('2');

  // A new application for class 1 picks up the requirement and shows it as
  // incomplete until enough photos are recorded.
  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('Checklist Child');
  await page.getByLabel('Date of birth').fill('2020-01-01');
  await page.getByLabel('Parent/guardian name').fill('Checklist Parent');
  await page.getByLabel('Phone').fill('03001234567');
  await page.getByRole('button', { name: 'Record enquiry' }).click();
  await expect(page.getByText('Enquiry recorded for Checklist Child.')).toBeVisible();

  const enquiryRow = page.locator('[data-testid^="enquiry-row-"]').filter({ hasText: 'Checklist Child' });
  await enquiryRow.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByText('Application submitted.')).toBeVisible();

  await page.goto('/admissions/applications');
  await page.waitForLoadState('networkidle');
  const appRow = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Checklist Child' });

  await appRow.getByRole('button', { name: 'Check checklist' }).click();
  await expect(appRow.getByText(/Incomplete.*passport photo/)).toBeVisible();

  // Record 1 of the 2 required photos — still incomplete.
  await appRow.locator('[data-testid^="checklist-status-trigger-"]').click();
  await page.getByRole('option', { name: 'uploaded', exact: true }).click();
  await appRow.locator('input[type="number"]').fill('1');
  await appRow.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Document status saved.')).toBeVisible();
  await expect(appRow.getByText(/Incomplete.*passport photo \(1\)/)).toBeVisible();

  // Record the 2nd photo — now complete.
  await appRow.locator('input[type="number"]').fill('2');
  await appRow.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Document status saved.')).toBeVisible();
  await expect(appRow.getByText('Complete')).toBeVisible();
});
