import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { makeSolidPng } from './fixtures/png';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@branding-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `branding-e2e-${runId}`,
    p_legal_name: `Branding E2E School ${runId}`,
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

test('an owner uploads a branding logo — too-small is refused, a valid one activates and renders via a signed link with no session', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/branding');
  await page.waitForLoadState('networkidle');

  // AC1: a logo narrower than the required minimum is rejected, naming it.
  await page.getByTestId('branding-file-input').setInputFiles({
    name: 'small-logo.png',
    mimeType: 'image/png',
    buffer: makeSolidPng(400, 300),
  });
  await page.getByTestId('branding-upload-submit').click();
  await expect(page.getByText('Image is too small — minimum width for a logo is 600px.')).toBeVisible();
  await expect(page.locator('[data-testid^="branding-asset-row-"]')).toHaveCount(0);

  // AC2/AC3: a valid tenant-wide logo uploads, activates, and is listed.
  await page.getByTestId('branding-file-input').setInputFiles({
    name: 'logo.png',
    mimeType: 'image/png',
    buffer: makeSolidPng(800, 600),
  });
  await page.getByTestId('branding-upload-submit').click();
  await expect(page.getByText('Branding asset uploaded.')).toBeVisible();

  const row = page.locator('[data-testid^="branding-asset-row-"]');
  await expect(row).toBeVisible();
  await expect(row).toContainText('logo · Tenant-wide');
  await expect(row).toContainText('v1 · 800×600px');

  const testId = await row.getAttribute('data-testid');
  const assetId = testId!.replace('branding-asset-row-', '');

  // AC5: rendering the asset via a signed link, with NO browser session at
  // all — a plain server-to-server fetch, not the logged-in page context.
  const signedResponse = await fetch(`http://127.0.0.1:3011/api/branding-asset/${assetId}`);
  expect(signedResponse.status).toBe(200);
  const { url: signedUrl } = (await signedResponse.json()) as { url: string };
  expect(signedUrl).toContain('/storage/v1/object/sign/branding/');

  const imageResponse = await fetch(signedUrl);
  expect(imageResponse.status).toBe(200);
  expect(imageResponse.headers.get('content-type')).toBe('image/png');

  // Theme colours save independently of the asset flow.
  await page.locator('#theme-primary').fill('#112233');
  await page.locator('#theme-secondary').fill('#445566');
  await page.getByTestId('theme-save').click();
  await expect(page.getByText('Theme saved.')).toBeVisible();
});
