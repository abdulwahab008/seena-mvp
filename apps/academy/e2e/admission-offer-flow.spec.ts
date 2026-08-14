import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSeatedClass() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@offer-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `offer-e2e-${runId}`,
    p_legal_name: `Offer E2E School ${runId}`,
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

  // Seeded directly (not via create_section's RPC), the same way other
  // e2e specs seed prerequisite data: create_section's own FORBIDDEN check
  // reads JWT claims a service-role call never carries. Capacity 1, so the
  // "seats left" count and the offer-holds-the-seat behaviour (FR-B06) are
  // both directly observable in the UI.
  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 1,
  });
  if (e4) throw e4;

  return { email, password };
}

test('an owner takes an enquiry through application, offer, and acceptance', async ({ page }) => {
  const { email, password } = await seedOwnerWithSeatedClass();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Capture the enquiry (FR-B01). Campus/session/source all default to the
  // tenant's only campus/session and 'walk_in' — only class is required.
  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('Offer Flow Child');
  await page.getByLabel('Date of birth').fill('2020-01-01');
  await page.getByLabel('Parent/guardian name').fill('Offer Flow Parent');
  await page.getByLabel('Phone').fill('03001234567');
  await page.getByRole('button', { name: 'Record enquiry' }).click();

  const enquiryCard = page.locator('[data-testid^="enquiry-row-"]').filter({ hasText: 'Offer Flow Child' });
  await expect(enquiryCard).toBeVisible();

  // Submit an application from that enquiry (FR-B08) — Class 1 needs no group.
  await enquiryCard.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByText('Application submitted.')).toBeVisible();
  await expect(enquiryCard.getByTestId(/^enquiry-status-/)).toHaveText('converted');

  // Issue an offer against the live (offer-aware, FR-B06) seat count (FR-B15).
  await page.goto('/admissions/applications');
  await page.waitForLoadState('networkidle');
  const appCard = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Offer Flow Child' });
  await expect(appCard).toBeVisible();
  await expect(appCard).toContainText('1 seat(s) left');
  await appCard.getByLabel('Admission fee').fill('5000');
  await appCard.getByRole('button', { name: 'Issue offer' }).click();
  await expect(page.getByText('Offer issued.')).toBeVisible();
  await expect(appCard).toContainText('offer expires');

  // Accept the offer (FR-B16).
  await appCard.getByRole('button', { name: 'Accept' }).click();
  await expect(page.getByText('Offer accepted.')).toBeVisible();
});
