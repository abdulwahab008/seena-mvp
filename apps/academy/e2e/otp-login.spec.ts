import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { deleteAuthUserByPhone } from './fixtures/auth-users';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// Matches [auth.sms.test_otp] in supabase/config.toml (bare digits, no "+" —
// GoTrue's own phone convention). Only one test number is configured, so
// this suite runs as a single seed + journey rather than per-scenario
// fixtures — a second concurrent user can't claim the same phone.
const TEST_PHONE = '923001234567';
// FR-A08's own otp_attempt ledger stores the +92 E.164 form, not GoTrue's.
const TEST_PHONE_E164 = '+923001234567';
const TEST_CODE = '123456';

async function seedOwnerWithPhone() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  // Idempotent across repeated local runs: only one auth.users row can ever
  // hold TEST_PHONE, so a prior run's leftover user must be cleared first —
  // and the search has to cover EVERY page, not just the first 50 users.
  await deleteAuthUserByPhone(admin, TEST_PHONE);

  // The other leftover that outlives a run: issue_otp() refuses a 7th code
  // for the same number within an hour (FR-A08), and otp_attempt rows are
  // keyed by phone, not by auth user, so deleting the user above does not
  // clear them. Without this the spec passes six times an hour and then
  // fails on "Too many codes requested" — a rate limit it never meant to
  // exercise. Only this fixture's own number is touched.
  const { error: e0 } = await admin.from('otp_attempt').delete().eq('phone_e164', TEST_PHONE_E164);
  if (e0) throw e0;

  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@otp-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `otp-e2e-${runId}`,
    p_legal_name: `OTP E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({
    email,
    phone: TEST_PHONE,
    email_confirm: true,
    phone_confirm: true,
  });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;
}

test('a wrong code is rejected, then the correct code signs the user in', async ({ page }) => {
  await seedOwnerWithPhone();

  await page.goto('/login/otp');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Mobile number').fill('03001234567');
  await page.getByRole('button', { name: 'Send code' }).click();
  await expect(page.getByText('Code sent to +923001234567.')).toBeVisible();

  await page.getByLabel('6-digit code').fill('000000');
  await page.getByRole('button', { name: 'Verify and sign in' }).click();
  await expect(page.getByText('Incorrect or expired code.')).toBeVisible();
  await expect(page).toHaveURL(/\/login\/otp$/);

  await page.getByLabel('6-digit code').fill(TEST_CODE);
  await page.getByRole('button', { name: 'Verify and sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
});
