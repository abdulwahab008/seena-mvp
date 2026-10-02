import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithFullClassAndSecondApplicant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@waitlist-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `waitlist-e2e-${runId}`,
    p_legal_name: `Waitlist E2E School ${runId}`,
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

  // Capacity 1, same seeding convention as admission-offer-flow.spec.ts.
  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 1,
  });
  if (e4) throw e4;

  // The first applicant takes the only seat, seeded directly through the
  // same enquiry -> application -> offer chain the RPCs themselves use, so
  // the second applicant (driven through the real UI below) genuinely has
  // no seat to be offered.
  const { data: enquiry1 } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'First In Line',
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
  const { data: application1 } = await admin
    .from('admission_application')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_id: enquiry1!.id,
      application_no: 'APP-2026-00001',
      class_applied_id: classLevel!.id,
      status: 'offered',
    })
    .select('id')
    .single();
  const { data: offer1, error: e5 } = await admin
    .from('admission_offer')
    .insert({
      tenant_id: tenantId as string,
      application_id: application1!.id,
      class_level_id: classLevel!.id,
      admission_fee_amount: 5000,
      expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
    })
    .select('id')
    .single();
  if (e5) throw e5;

  return { email, password, offer1Id: offer1!.id as string };
}

test('an owner joins a waitlisted applicant to the queue, and a lapsed offer auto-promotes them', async ({ page }) => {
  const { email, password, offer1Id } = await seedOwnerWithFullClassAndSecondApplicant();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // The second applicant, taken through the real enquiry -> application UI.
  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('Second In Line');
  await page.getByLabel('Date of birth').fill('2019-02-02');
  await page.getByLabel('Parent/guardian name').fill('Parent Two');
  await page.getByLabel('Phone').fill('03002222222');
  await page.getByRole('button', { name: 'Record enquiry' }).click();
  await expect(page.getByText('Enquiry recorded for Second In Line.')).toBeVisible();

  // Submit the application through the real UI (not a service-role RPC
  // call — fn_submit_application's own role/tenant checks read JWT claims
  // a service-role client never carries).
  const enquiryRow = page.locator('[data-testid^="enquiry-row-"]').filter({ hasText: 'Second In Line' });
  await enquiryRow.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByText('Application submitted.')).toBeVisible();

  await page.goto('/admissions/applications');
  await page.waitForLoadState('networkidle');

  const row = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Second In Line' });
  await expect(row).toContainText('0 seat(s) left');
  await row.getByRole('button', { name: 'Join waitlist' }).click();
  await expect(page.getByText('Added to the waitlist.')).toBeVisible();
  await expect(row).toContainText('Waitlist position 1');

  // The first applicant's offer lapses — auto-promotes the waitlisted one.
  const { error } = await admin.from('admission_offer').update({ status: 'lapsed' }).eq('id', offer1Id);
  if (error) throw error;

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Second In Line' })).toContainText(
    'Promoted — ready for an offer'
  );
});
