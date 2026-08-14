import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithExistingEnquiry() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@dup-enquiry-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `dup-enquiry-e2e-${runId}`,
    p_legal_name: `Dup Enquiry E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus, error: eCampus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  if (eCampus || !campus) throw eCampus ?? new Error('campus not seeded');
  const { data: session, error: eSession } = await admin
    .from('academic_session')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .single();
  if (eSession || !session) throw eSession ?? new Error('session not seeded');
  const { data: class1, error: eClass1 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  if (eClass1 || !class1) throw eClass1 ?? new Error('class level not seeded');

  // Seeded directly, same as other e2e specs: create_enquiry's own role
  // check reads JWT claims a service-role call never carries.
  const { data: existing, error: e4 } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus.id,
      session_id: session.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'Muhammad Ali',
      dob: '2020-01-01',
      class_applied_id: class1.id,
      parent_name: 'Parent One',
      phone_e164: '+923001234567',
      whatsapp_opt_in: false,
      source: 'walk_in',
    })
    .select('enquiry_no')
    .single();
  if (e4 || !existing) throw e4 ?? new Error('existing enquiry seeding failed');

  return { email, password, existingEnquiryNo: existing.enquiry_no as string };
}

test('an owner saving an enquiry with a matching phone sees the existing one flagged, and can merge them', async ({ page }) => {
  const { email, password, existingEnquiryNo } = await seedOwnerWithExistingEnquiry();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/admissions/enquiries');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('enquiry-class-trigger').click();
  await page.getByRole('option', { name: 'Class 1', exact: true }).click();
  await page.getByLabel("Child's name").fill('M. Ali');
  await page.getByLabel('Date of birth').fill('2020-01-01');
  await page.getByLabel('Parent/guardian name').fill('Parent One');
  // Same phone as the pre-seeded enquiry, different formatting.
  await page.getByLabel('Phone').fill('0300-1234567');
  await page.getByRole('button', { name: 'Record enquiry' }).click();

  await expect(page.getByText('Enquiry recorded for M. Ali.')).toBeVisible();

  // AC: the duplicate panel lists the existing enquiry by its enquiry_no.
  const panel = page.getByTestId('duplicate-enquiry-panel');
  await expect(panel).toBeVisible();
  const candidate = page.getByTestId(`duplicate-candidate-${existingEnquiryNo}`);
  await expect(candidate).toBeVisible();
  await expect(candidate).toContainText('Muhammad Ali');

  // AC: choosing Merge re-parents and the loser becomes 'merged' — the
  // panel entry clears once handled.
  await candidate.getByRole('button', { name: 'Merge' }).click();
  await expect(page.getByText('Enquiries merged.')).toBeVisible();
  await expect(candidate).not.toBeVisible();
});
