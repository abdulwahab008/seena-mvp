import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// Smoke test for FR-A01/FR-A02 through the real UI, against the local
// Supabase stack. Test setup seeds a tenant + owner directly via the
// service-role client — the invitation-redemption flow that would normally
// turn a tenant_invitation into this app_user row is not built yet (see the
// foundation migration's header comment), so this is standing in for it.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const slug = `e2e-school-${runId}`;
  const email = `owner-${runId}@e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: provisionErr } = await admin.rpc('provision_tenant', {
    p_slug: slug,
    p_legal_name: `E2E School ${runId}`,
    p_owner_email: email,
  });
  if (provisionErr) throw provisionErr;

  const { data: created, error: createUserErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (createUserErr || !created.user) throw createUserErr ?? new Error('user creation failed');

  const { error: appUserErr } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (appUserErr) throw appUserErr;

  return { email, password, slug };
}

test('owner logs in and manages campuses (FR-A01 seed + FR-A02 create/archive)', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  // Playwright's click auto-waits on the element being actionable, but not
  // specifically on React hydration completing — clicking the (visually
  // ready, SSR'd) submit button before hydration attaches its handler falls
  // through to a native form GET, landing on /login?email=...&password=...
  // Waiting for the network to settle after navigation is enough headroom.
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();

  // Signing in with no requested destination lands on the dashboard — this
  // test is about /campuses, so navigate there.
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.goto('/campuses');
  await expect(page.getByRole('heading', { name: 'Campuses' })).toBeVisible();

  // The seeded MAIN campus from provision_tenant should already be listed.
  await expect(page.getByText('MAIN')).toBeVisible();

  // Create a second campus.
  await page.getByLabel('Code').fill('DHA');
  await page.getByLabel('Name').fill('DHA Campus');
  await page.getByLabel('City').fill('Lahore');
  await page.getByRole('button', { name: 'Add campus' }).click();

  await expect(page.getByTestId('campus-card-DHA')).toBeVisible();
  await expect(page.getByTestId('campus-card-DHA')).toContainText('DHA Campus');

  // Duplicate code is rejected with the exact error the DB function raises.
  await page.getByLabel('Code').fill('dha');
  await page.getByLabel('Name').fill('Duplicate Attempt');
  await page.getByRole('button', { name: 'Add campus' }).click();
  await expect(page.getByText('Campus code "dha" is already in use.')).toBeVisible();

  // Archive the campus we just created. The card stays visible (schools want
  // a record that it existed) but flips to "archived" and loses its Archive
  // button — it doesn't vanish from the list.
  const dhaCard = page.getByTestId('campus-card-DHA');
  await dhaCard.getByRole('button', { name: 'Archive' }).click();
  await expect(dhaCard).toContainText('archived');
  await expect(dhaCard.getByRole('button', { name: 'Archive' })).not.toBeVisible();
});

test('unauthenticated visitor is redirected to /login', async ({ page }) => {
  await page.goto('/campuses');
  // The requested page is preserved so signing in returns the visitor to it.
  await expect(page).toHaveURL('/login?redirectTo=%2Fcampuses');
});
