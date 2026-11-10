import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const PASSWORD = 'e2e-test-password-123!';

test('a parent signs out of the portal and the portal is closed to them afterwards', async ({ page }) => {
  const db = createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `signout-e2e-${runId}`,
    p_legal_name: `Sign-out E2E School ${runId}`,
    p_owner_email: `owner-${runId}@signout-e2e.test`,
  });
  if (e1) throw e1;
  const email = `parent-${runId}@signout-e2e.test`;
  const { data: parent, error: e2 } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
  if (e2 || !parent.user) throw e2 ?? new Error('parent creation failed');
  const { error: e3 } = await db
    .from('guardian')
    .insert({ tenant_id: tenantId as string, name_en: 'E2E Parent', auth_user_id: parent.user.id });
  if (e3) throw e3;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/portal\//);

  await page.getByRole('button', { name: 'Sign out' }).click();
  await expect(page).toHaveURL(/\/login\?signed_out=1$/);

  await page.goto('/portal/fees');
  await expect(page).toHaveURL(/\/login\?redirectTo=%2Fportal%2Ffees$/);
});
