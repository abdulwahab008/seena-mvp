import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithPanelAndApplications() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@interview-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `interview-e2e-${runId}`,
    p_legal_name: `Interview E2E School ${runId}`,
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

  const panelEmail = `principal-${runId}@interview-e2e.test`;
  const { data: panelCreated, error: e4 } = await admin.auth.admin.createUser({ email: panelEmail, password, email_confirm: true });
  if (e4 || !panelCreated.user) throw e4 ?? new Error('panel user creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: panelCreated.user.id, tenant_id: tenantId as string, app_role: 'principal', full_name: 'Ms. Principal' });
  if (e5) throw e5;
  const { error: e6 } = await admin.from('staff').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    user_id: panelCreated.user.id,
    employee_code: `PRIN-${runId}`,
    gender: 'female',
    cnic: '42101-1234567-8',
    full_name: 'Ms. Principal',
  });
  if (e6) throw e6;

  async function seedApplication(no: string, childName: string, whatsappOptIn: boolean) {
    const { data: enquiry } = await admin
      .from('admission_enquiry')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: session!.id,
        enquiry_no: no,
        child_name: childName,
        dob: '2020-01-01',
        class_applied_id: classLevel!.id,
        parent_name: 'Parent',
        phone_e164: `+92300${no.slice(-7)}`,
        whatsapp_opt_in: whatsappOptIn,
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

  await seedApplication('IVIEW-0000001', 'Interview One', false);
  await seedApplication('IVIEW-0000002', 'Interview Two', true);

  return { email, password };
}

test('an owner books an interview slot, a conflicting attempt is refused, cancelling frees it, and the notification channel is previewed', async ({
  page,
}) => {
  const { email, password } = await seedOwnerWithPanelAndApplications();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/admissions/interviews');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('interview-application-trigger').click();
  await page.getByRole('option', { name: /Interview One/ }).click();
  await page.getByTestId('interview-panel-trigger').click();
  await page.getByRole('option', { name: /Ms\. Principal/ }).click();
  await page.locator('#interviewStartsAt').fill('2026-08-10T11:00');
  await page.locator('#interviewEndsAt').fill('2026-08-10T11:20');
  await page.locator('#interviewVenue').fill('Principal office');
  await page.getByRole('button', { name: 'Book interview' }).click();
  await expect(page.getByText('Interview booked.')).toBeVisible();

  const row1 = page.locator('[data-testid^="interview-row-"]').filter({ hasText: 'Interview One' });
  await expect(row1).toBeVisible();

  // AC: an overlapping window for the same panel member is refused.
  await page.getByTestId('interview-application-trigger').click();
  await page.getByRole('option', { name: /Interview Two/ }).click();
  await page.getByTestId('interview-panel-trigger').click();
  await page.getByRole('option', { name: /Ms\. Principal/ }).click();
  await page.locator('#interviewStartsAt').fill('2026-08-10T11:10');
  await page.locator('#interviewEndsAt').fill('2026-08-10T11:30');
  await page.getByRole('button', { name: 'Book interview' }).click();
  await expect(page.getByText(/already has a booking that overlaps/)).toBeVisible();

  // AC: cancelling frees the window, and the exact same window can be
  // rebooked immediately with no manual cleanup.
  await row1.getByRole('button', { name: 'Cancel' }).click();
  await expect(page.getByText('Interview cancelled.')).toBeVisible();
  await expect(row1.getByTestId(/interview-status-/)).toHaveText('cancelled');

  await page.getByTestId('interview-application-trigger').click();
  await page.getByRole('option', { name: /Interview Two/ }).click();
  await page.getByTestId('interview-panel-trigger').click();
  await page.getByRole('option', { name: /Ms\. Principal/ }).click();
  await page.locator('#interviewStartsAt').fill('2026-08-10T11:00');
  await page.locator('#interviewEndsAt').fill('2026-08-10T11:20');
  await page.getByRole('button', { name: 'Book interview' }).click();
  await expect(page.getByText('Interview booked.')).toBeVisible();

  const row2 = page.locator('[data-testid^="interview-row-"]').filter({ hasText: 'Interview Two' });
  await expect(row2).toBeVisible();

  // AC: the notification channel resolves from the enquiry's own
  // WhatsApp opt-in.
  await row2.getByRole('button', { name: 'Preview notification' }).click();
  await expect(row2.getByText(/Channel: whatsapp/)).toBeVisible();
});
