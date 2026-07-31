import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSeatedClass() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@enrol-gate-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `enrol-gate-e2e-${runId}`,
    p_legal_name: `Enrol Gate E2E School ${runId}`,
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

test('an owner gates enrolment on the admission fee — a shortfall is refused, full settlement enrols atomically', async ({ page }) => {
  const { email, password } = await seedOwnerWithSeatedClass();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('Gate Flow Child');
  await page.getByLabel('Date of birth').fill('2020-01-01');
  await page.getByLabel('Parent/guardian name').fill('Gate Flow Parent');
  await page.getByLabel('Phone').fill('03009991111');
  await page.getByRole('button', { name: 'Record enquiry' }).click();
  const enquiryCard = page.locator('[data-testid^="enquiry-row-"]').filter({ hasText: 'Gate Flow Child' });
  await expect(enquiryCard).toBeVisible();
  await enquiryCard.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByText('Application submitted.')).toBeVisible();

  await page.goto('/admissions/applications');
  await page.waitForLoadState('networkidle');
  const appCard = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Gate Flow Child' });
  await expect(appCard).toBeVisible();
  await appCard.getByLabel('Admission fee').fill('25000');
  await appCard.getByRole('button', { name: 'Issue offer' }).click();
  await expect(page.getByText('Offer issued.')).toBeVisible();
  await appCard.getByRole('button', { name: 'Accept' }).click();
  await expect(page.getByText('Offer accepted.')).toBeVisible();

  // AC1: a partial cash payment leaves the gate refused, naming the shortfall.
  await appCard.getByTestId(/^payment-amount-/).fill('20000');
  await appCard.getByTestId(/^record-payment-submit-/).click();
  await expect(page.getByText('Payment recorded.')).toBeVisible();

  await appCard.getByTestId(/^enrol-funding-trigger-/).click();
  await page.getByRole('option', { name: /Payment PKR 20,000/ }).click();
  await appCard.getByTestId(/^enrol-submit-/).click();
  await expect(page.getByText('Outstanding PKR 5,000.')).toBeVisible();
  await expect(appCard.getByTestId(/^application-status-/)).not.toHaveText('enrolled');

  // AC2: topping up to the full amount enrols atomically — GR number shown,
  // application marked enrolled.
  await appCard.getByTestId(/^payment-amount-/).fill('5000');
  await appCard.getByTestId(/^record-payment-submit-/).click();
  await expect(page.getByText('Payment recorded.')).toBeVisible();

  await appCard.getByTestId(/^enrol-funding-trigger-/).click();
  await page.getByRole('option', { name: /Payment PKR 5,000/ }).click();
  await appCard.getByTestId(/^enrol-submit-/).click();
  await expect(page.getByText(/^Enrolled — GR /)).toBeVisible();
  await expect(appCard.getByTestId(/^application-status-/)).toHaveText('enrolled');

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Gate Flow Child')).toBeVisible();
});
