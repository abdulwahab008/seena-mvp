import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@attendance-policy-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `attendance-policy-e2e-${runId}`,
    p_legal_name: `Attendance Policy E2E School ${runId}`,
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

test('an owner configures the attendance policy — the screen blocks until it is set, then classifies present vs late', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/attendance-policy');
  await page.waitForLoadState('networkidle');

  // AC1: nothing configured yet — the screen says so plainly.
  await expect(page.getByTestId('attendance-policy-unconfigured')).toContainText(
    'Attendance policy not configured for this session — contact your Principal.'
  );

  await page.getByTestId('attendance-start-time').fill('08:00');
  await page.getByTestId('attendance-late-threshold').fill('15');
  await page.getByTestId('attendance-lock-window').fill('24');
  await page.getByTestId('attendance-policy-save').click();
  await expect(page.getByText('Attendance policy saved.')).toBeVisible();

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('attendance-policy-unconfigured')).toHaveCount(0);

  // AC2: 08:14 is inside the 15-minute threshold of an 08:00 start — Present.
  await page.locator('#preview-time').fill('08:14');
  await page.getByTestId('attendance-status-preview-check').click();
  await expect(page.getByTestId('attendance-status-preview-result')).toHaveText('present');

  // 08:16 is one minute past the threshold — Late.
  await page.locator('#preview-time').fill('08:16');
  await page.getByTestId('attendance-status-preview-check').click();
  await expect(page.getByTestId('attendance-status-preview-result')).toHaveText('late');
});
