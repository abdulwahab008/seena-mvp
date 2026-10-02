import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// Route gating: what an anonymous visitor can reach, where they land after
// signing in, and what survives sign-out.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

async function seedOwner() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const email = `gate-${runId}@e2e.test`;

  const { data: tenantId, error: provisionErr } = await db.rpc('provision_tenant', {
    p_slug: `e2e-gate-${runId}`,
    p_legal_name: `E2E Gate School ${runId}`,
    p_owner_email: email,
  });
  if (provisionErr) throw provisionErr;

  const { data: created, error: createErr } = await db.auth.admin.createUser({
    email,
    password: PASSWORD,
    email_confirm: true,
  });
  if (createErr || !created.user) throw createErr ?? new Error('user creation failed');

  const { error: appUserErr } = await db.from('app_user').insert({
    user_id: created.user.id,
    tenant_id: tenantId as string,
    app_role: 'owner',
    full_name: 'E2E Gate Owner',
  });
  if (appUserErr) throw appUserErr;

  return { email };
}

test('a protected URL opened while signed out returns the user to it after signing in', async ({
  page,
}) => {
  const { email } = await seedOwner();

  // Straight to a deep page, no session — as if from a bookmark or a new tab.
  await page.goto('/students');
  await expect(page).toHaveURL('/login?redirectTo=%2Fstudents');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();

  // Back to what was originally asked for, not the default dashboard.
  await expect(page).toHaveURL(/\/students$/);
  await expect(page.getByRole('heading', { name: 'Students' })).toBeVisible();
});

test('an off-site redirectTo is refused and falls back to the dashboard', async ({ page }) => {
  const { email } = await seedOwner();

  await page.goto('/login?redirectTo=https%3A%2F%2Fevil.example%2Fphish');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();

  await expect(page).toHaveURL(/\/dashboard$/);
  expect(page.url()).not.toContain('evil.example');
});

test('after sign-out the app is unreachable, including via the back button', async ({ page }) => {
  const { email } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await expect(page.getByRole('heading', { name: 'Students' })).toBeVisible();

  await page.getByTestId('user-menu-trigger').click();
  await page.getByTestId('sign-out').click();
  await expect(page).toHaveURL(/\/login\?signed_out=1$/);
  await expect(page.getByTestId('signed-out-notice')).toBeVisible();

  // The back button must not serve the cached authenticated render.
  await page.goBack();
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByRole('heading', { name: 'Students' })).toHaveCount(0);

  // Nor is a fresh navigation allowed through.
  await page.goto('/students');
  await expect(page).toHaveURL('/login?redirectTo=%2Fstudents');
});

test('protected responses are marked no-store so nothing is cached for replay', async ({
  page,
  request,
}) => {
  const { email } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  const response = await page.request.get('/students');
  expect(response.status()).toBe(200);
  expect(response.headers()['cache-control']).toContain('no-store');

  // An anonymous API call is refused outright rather than 404-ing after a
  // pointless database round trip.
  const anon = await request.get('/api/report-cards/00000000-0000-0000-0000-000000000000/download');
  expect(anon.status()).toBe(401);
});

test('surfaces that must stay public are still reachable with no session', async ({ request }) => {
  // Each of these is public for a specific reason (see middleware.ts) and a
  // default-deny gate must not have swept them up.
  for (const path of ['/login', '/sign-up', '/forgot-password', '/reset-password', '/admin/provision']) {
    const response = await request.get(path);
    expect(response.status(), `${path} should be publicly reachable`).toBe(200);
  }
});
