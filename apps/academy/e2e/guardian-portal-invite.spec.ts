import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// Matches the second [auth.sms.test_otp] fixture in supabase/config.toml —
// deliberately distinct from otp-login.spec.ts's own TEST_PHONE so the two
// specs' concurrent auth.users churn never races the same phone number.
const TEST_PHONE = '923005551234';
const TEST_PHONE_E164 = '+923005551234';
const TEST_CODE = '654321';

async function seedOwnerWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  const { data: existing } = await admin.auth.admin.listUsers();
  const stale = existing?.users.find((u) => u.phone === TEST_PHONE);
  if (stale) await admin.auth.admin.deleteUser(stale.id);

  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@guardian-invite-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `guardian-invite-e2e-${runId}`,
    p_legal_name: `Guardian Invite E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  const { error: e4 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 });
  if (e4) throw e4;

  return { email, password, tenantId: tenantId as string };
}

test('an owner sends a print invite and the guardian activates their portal account via OTP', async ({ page }) => {
  const { email, password, tenantId } = await seedOwnerWithSection();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Admit and enrol through the real UI — enrolment's own AFTER INSERT
  // trigger (fee-plan auto-build) needs a JWT, same gotcha every e2e spec
  // in this suite works around by never inserting enrolment rows directly.
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Guardian E2E Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Guardian E2E Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // Linking a guardian record (not an enrolment row) has no such trigger —
  // seeded directly, same as this suite's other non-enrolment fixtures.
  const { data: guardian, error: eg } = await admin
    .from('guardian')
    .insert({ tenant_id: tenantId, name_en: 'E2E Guardian', phone_e164: TEST_PHONE_E164 })
    .select('id')
    .single();
  if (eg) throw eg;
  const { error: el } = await admin
    .from('student_guardian')
    .insert({ tenant_id: tenantId, student_id: studentId, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });
  if (el) throw el;

  await page.goto(`/students/${studentId}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('guardian-row-E2E Guardian')).toBeVisible();

  const channelTrigger = page.locator('[data-testid^="guardian-invite-channel-"]');
  await channelTrigger.click();
  await page.getByRole('option', { name: 'Print slip' }).click();
  await page.locator('[data-testid^="guardian-invite-send-"]').click();

  const linkEl = page.locator('[data-testid^="guardian-invite-link-"]');
  await expect(linkEl).toBeVisible();
  const activationUrl = (await linkEl.textContent())!.trim();
  expect(activationUrl).toContain('/guardian/activate/');

  await page.goto(activationUrl);
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Activate your parent portal account, E2E Guardian.')).toBeVisible();
  await expect(page.getByText(`We'll send a verification code to ${TEST_PHONE_E164}.`)).toBeVisible();

  await page.getByTestId('activate-request-code').click();
  await expect(page.getByText(`Code sent to ${TEST_PHONE_E164}.`)).toBeVisible();

  await page.getByLabel('6-digit code').fill('000000');
  await page.getByTestId('activate-verify-code').click();
  await expect(page.getByText('Incorrect or expired code.')).toBeVisible();

  await page.getByLabel('6-digit code').fill(TEST_CODE);
  await page.getByTestId('activate-verify-code').click();
  await expect(page.getByText('Account activated.')).toBeVisible();
  await expect(page).toHaveURL(/\/portal\/homework$/);

  // Re-visiting the same (now-consumed) link must not activate a second time.
  await page.goto(activationUrl);
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('Invite not valid')).toBeVisible();
});
