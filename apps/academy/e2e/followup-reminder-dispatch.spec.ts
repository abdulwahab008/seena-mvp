import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedReminderScenario() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@reminder-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `reminder-e2e-${runId}`,
    p_legal_name: `Reminder E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: officerUser, error: e4 } = await admin.auth.admin.createUser({
    email: `officer-${runId}@reminder-e2e.test`,
    password,
    email_confirm: true,
  });
  if (e4 || !officerUser.user) throw e4 ?? new Error('officer creation failed');
  const { error: e5 } = await admin.from('app_user').insert({
    user_id: officerUser.user.id,
    tenant_id: tenantId as string,
    app_role: 'admissions_officer',
    full_name: 'Officer One',
    phone_e164: '+923004445555',
  });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: enquiry1 } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'Followup Child',
      dob: '2020-01-01',
      class_applied_id: classLevel!.id,
      parent_name: 'Parent One',
      phone_e164: '+923001111111',
      whatsapp_opt_in: false,
      source: 'walk_in',
      status: 'open',
    })
    .select('id')
    .single();
  const { error: e6 } = await admin.from('admission_followup').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    enquiry_id: enquiry1!.id,
    channel: 'call',
    due_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    assigned_to: officerUser.user.id,
  });
  if (e6) throw e6;

  const { data: enquiryUr } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00002',
      child_name: 'Urdu Child',
      child_name_ur: 'اردو چائلڈ',
      dob: '2020-01-01',
      class_applied_id: classLevel!.id,
      parent_name: 'Parent Two',
      phone_e164: '+923002222222',
      whatsapp_opt_in: true,
      source: 'walk_in',
      status: 'converted',
    })
    .select('id')
    .single();
  const { data: appUr } = await admin
    .from('admission_application')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_id: enquiryUr!.id,
      application_no: 'APP-2026-00001',
      class_applied_id: classLevel!.id,
      status: 'submitted',
    })
    .select('id')
    .single();
  const { data: sitting } = await admin
    .from('admission_test_sitting')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      starts_at: new Date(Date.now() + 2 * 60 * 60 * 1000).toISOString(),
      capacity: 5,
    })
    .select('id')
    .single();
  const { error: e7 } = await admin
    .from('admission_test_candidate')
    .insert({ tenant_id: tenantId as string, sitting_id: sitting!.id, application_id: appUr!.id, seat_no: 1 });
  if (e7) throw e7;

  return { email, password };
}

test('an owner queues follow-up and appointment reminders through the real UI, with dedupe and Urdu template selection', async ({ page }) => {
  const { email, password } = await seedReminderScenario();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/admissions/reminders');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('run-followup-queue').click();
  await expect(page.getByText('Follow-up reminders: 1 new row(s) processed.')).toBeVisible();

  const followupRow = page.locator('[data-testid^="reminder-row-"]').filter({ hasText: 'Followup Child' });
  await expect(followupRow).toBeVisible();
  await expect(followupRow).toContainText('whatsapp');
  await expect(followupRow.getByTestId(/reminder-status-/)).toHaveText('queued');

  // AC: re-running the queue creates no duplicate row for the same
  // follow-up — the dedupe key absorbs the re-run.
  await page.getByTestId('run-followup-queue').click();
  await expect(page.getByText('Follow-up reminders: 0 new row(s) processed.')).toBeVisible();
  await expect(page.locator('[data-testid^="reminder-row-"]').filter({ hasText: 'Followup Child' })).toHaveCount(1);

  // AC: the Urdu child's upcoming test sitting reminder picks the
  // Urdu-approved template.
  await page.getByTestId('run-appointment-queue').click();
  await expect(page.getByText(/Appointment reminders: \d+ new row\(s\) processed\./)).toBeVisible();

  const urduRow = page.locator('[data-testid^="reminder-row-"]').filter({ hasText: 'Urdu Child' });
  await expect(urduRow).toBeVisible();
  await expect(urduRow).toContainText('whatsapp');
  await expect(urduRow).toContainText('test_reminder_whatsapp_ur_v1');

  // AC: simulating a permanent WhatsApp delivery failure leaves the
  // follow-up reminder visibly failed, and an immediate fallback pass
  // (before 5 minutes have passed) queues nothing yet.
  await followupRow.getByRole('button', { name: 'Simulate delivery failure' }).click();
  await expect(page.getByText('Marked failed.')).toBeVisible();
  await expect(followupRow.getByTestId(/reminder-status-/)).toHaveText('failed');

  await page.getByTestId('run-sms-fallbacks').click();
  await expect(page.getByText('SMS fallbacks: 0 new row(s) processed.')).toBeVisible();
});
