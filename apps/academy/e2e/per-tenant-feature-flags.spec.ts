import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A17: a Super Admin switches a module off for one school. The nav item
// disappears, the module's own RPC starts returning 403 FEATURE_DISABLED, the
// data underneath is untouched, and switching it back on restores both.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const email = `super-${runId}@feature-flags-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `feature-flags-e2e-${runId}`,
    p_legal_name: `Feature Flags E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { error: e2 } = await admin.rpc('seed_default_expense_heads', { p_tenant_id: tenantId as string });
  if (e2) throw e2;

  const { data: created, error: e3 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e3 || !created.user) throw e3 ?? new Error('user creation failed');
  const { error: e4 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'super_admin', full_name: 'Platform' });
  if (e4) throw e4;
  const { error: e5 } = await admin
    .from('user_campus')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e5) throw e5;

  return { admin, email, password, tenantId: tenantId as string };
}

test('a super admin switches Expenses off for one school — the nav goes, the RPC 403s, the data stays', async ({
  page,
}) => {
  const { admin, email, password, tenantId } = await seed();

  const { count: headsBefore } = await admin
    .from('expense_head')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(headsBefore).toBeGreaterThan(0);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Nothing gated yet: the Expenses section is in the nav.
  await expect(page.getByRole('navigation', { name: 'Main' }).getByText('Expenses')).toBeVisible();

  await page.goto('/feature-flags');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('feature-flags-view')).toBeVisible();
  await expect(page.getByTestId('flag-state-module.expenses')).toHaveText('On');

  // AC2/AC3: the toggle takes effect on the next read — no redeploy, no
  // re-login — and the nav item goes with it.
  await page.getByTestId('flag-toggle-module.expenses').click();
  await expect(page.getByTestId('flag-state-module.expenses')).toHaveText('Off');
  await expect(page.getByTestId('flag-override-module.expenses')).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Main' }).getByText('Expenses')).toHaveCount(0);

  // AC3: hiding the nav is not the control. The module's own SECURITY DEFINER
  // RPC, called straight from a client with the same signed-in session, is
  // refused and writes nothing.
  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signedIn } = await anon.auth.signInWithPassword({ email, password });
  const asUser = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${signedIn.session!.access_token}` } },
  });

  const { error: blocked } = await asUser.rpc('create_expense_head', {
    p_code: 'SNEAK',
    p_name_en: 'Sneak',
    p_name_ur: 'Sneak',
  });
  expect(blocked?.message).toContain('FEATURE_DISABLED');

  const { count: sneaked } = await admin
    .from('expense_head')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId)
    .eq('code', 'SNEAK');
  expect(sneaked).toBe(0);

  // AC4: the module is hidden, not emptied. The rows are still there, and the
  // tenant's own session cannot see them while it is off.
  const { count: headsWhileOff } = await admin
    .from('expense_head')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(headsWhileOff).toBe(headsBefore);

  const { count: visibleWhileOff } = await asUser
    .from('expense_head')
    .select('id', { count: 'exact', head: true });
  expect(visibleWhileOff).toBe(0);

  // AC4: back on, and everything returns exactly as it was.
  await page.getByTestId('flag-toggle-module.expenses').click();
  await expect(page.getByTestId('flag-state-module.expenses')).toHaveText('On');
  await expect(page.getByRole('navigation', { name: 'Main' }).getByText('Expenses')).toBeVisible();

  const { count: visibleAfter } = await asUser
    .from('expense_head')
    .select('id', { count: 'exact', head: true });
  expect(visibleAfter).toBe(headsBefore);
});

test('an owner sees the resolved modules read-only and cannot toggle one', async ({ page }) => {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const email = `owner-${runId}@feature-flags-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `feature-flags-owner-${runId}`,
    p_legal_name: `Feature Flags Owner School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'Owner' });
  await admin
    .from('user_campus')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/feature-flags');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('flag-state-module.expenses')).toHaveText('On');
  await expect(page.getByTestId('flag-toggle-module.expenses')).toHaveCount(0);
  await expect(page.getByTestId('plan-select')).toHaveCount(0);

  // The refusal is server-side, not just an absent button.
  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signedIn } = await anon.auth.signInWithPassword({ email, password });
  const asOwner = createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${signedIn.session!.access_token}` } },
  });
  const { error } = await asOwner.rpc('set_tenant_feature', {
    p_tenant_id: tenantId as string,
    p_code: 'module.expenses',
    p_enabled: false,
  });
  expect(error?.message).toContain('FORBIDDEN');
});
