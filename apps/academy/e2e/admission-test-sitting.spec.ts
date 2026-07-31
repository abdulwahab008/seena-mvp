import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithOneSubmittedApplication() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@sitting-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `sitting-e2e-${runId}`,
    p_legal_name: `Sitting E2E School ${runId}`,
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

  // Seeded directly (a service-role client carries no JWT, so
  // fn_submit_application's own tenant lookup would reject it) — the
  // second applicant below goes through the real UI instead.
  const { data: enquiry1 } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'First Candidate',
      dob: '2019-01-01',
      class_applied_id: classLevel!.id,
      parent_name: 'Parent One',
      phone_e164: '+923001111111',
      whatsapp_opt_in: false,
      source: 'walk_in',
      status: 'converted',
    })
    .select('id')
    .single();
  const { error: e4 } = await admin.from('admission_application').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    enquiry_id: enquiry1!.id,
    application_no: 'APP-2026-00001',
    class_applied_id: classLevel!.id,
    status: 'submitted',
  });
  if (e4) throw e4;

  return { email, password };
}

test('an owner schedules a test sitting, allocates seats, and a full sitting rejects the next allocation', async ({ page }) => {
  const { email, password } = await seedOwnerWithOneSubmittedApplication();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  // The second candidate, taken through the real enquiry -> application UI.
  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('Second Candidate');
  await page.getByLabel('Date of birth').fill('2019-02-02');
  await page.getByLabel('Parent/guardian name').fill('Parent Two');
  await page.getByLabel('Phone').fill('03002222222');
  await page.getByRole('button', { name: 'Record enquiry' }).click();
  await expect(page.getByText('Enquiry recorded for Second Candidate.')).toBeVisible();

  const enquiryRow = page.locator('[data-testid^="enquiry-row-"]').filter({ hasText: 'Second Candidate' });
  await enquiryRow.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByText('Application submitted.')).toBeVisible();

  // Schedule a capacity-1 sitting for Class 1.
  await page.goto('/admissions/test-sittings');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('sitting-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.locator('#startsAt').fill('2026-08-10T09:00');
  await page.locator('#venue').fill('Main hall');
  await page.locator('#capacity').fill('1');
  await page.getByRole('button', { name: 'Schedule sitting' }).click();
  await expect(page.getByText('Test sitting scheduled.')).toBeVisible();

  const sittingRow = page.locator('[data-testid^="sitting-row-"]').filter({ hasText: 'Main hall' });
  await expect(sittingRow).toBeVisible();

  // Allocate the first candidate — fills the only seat.
  await sittingRow.locator('[data-testid^="allocate-app-trigger-"]').click();
  await page.getByRole('option', { name: /First Candidate/ }).click();
  await sittingRow.getByRole('button', { name: 'Allocate seat' }).click();
  await expect(page.getByText('Allocated seat 1.')).toBeVisible();
  await expect(sittingRow.locator('[data-testid^="sitting-seats-"]')).toHaveText('1');

  // AC: allocating the second candidate into the now-full sitting is
  // rejected — no seat is consumed.
  await sittingRow.locator('[data-testid^="allocate-app-trigger-"]').click();
  await page.getByRole('option', { name: /Second Candidate/ }).click();
  await sittingRow.getByRole('button', { name: 'Allocate seat' }).click();
  await expect(page.getByText('This sitting is full.')).toBeVisible();
  await expect(sittingRow.locator('[data-testid^="sitting-seats-"]')).toHaveText('1');

  // The roll slip lists exactly the one active candidate.
  await sittingRow.getByRole('button', { name: 'View roll slip' }).click();
  await expect(sittingRow.getByText(/Seat 1 — First Candidate/)).toBeVisible();
});
