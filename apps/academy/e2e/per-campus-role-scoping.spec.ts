import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A12: per-campus role scoping. AC2 (fee dashboard's campus filter
// offers one option per accessible campus plus "All campuses") and AC4 (a
// staff member with zero campuses assigned sees a "no campus assigned"
// screen, not an empty/broken dashboard) exercised through the real UI.
//
// There is no invite/edit-scope UI yet that can grant more than one campus
// to a staff member (see 20260731760000_per_campus_role_scoping.sql's own
// header for why) — user_campus rows are seeded directly via the
// service-role client here, the same stand-in campus-management.spec.ts
// already uses for app_user itself.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

function adminClient() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

async function seedTenantWithCampuses(campusCount: number) {
  const admin = adminClient();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@campus-scoping-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `campus-scoping-e2e-${runId}`,
    p_legal_name: `Campus Scoping E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: mainCampus, error: e2 } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  if (e2 || !mainCampus) throw e2 ?? new Error('seeded MAIN campus not found');

  const campusIds: string[] = [mainCampus.id as string];
  for (let i = 1; i < campusCount; i++) {
    const { data: c, error } = await admin
      .from('campus')
      .insert({ tenant_id: tenantId as string, code: `C${i}`, name: `Campus ${i}` })
      .select('id')
      .single();
    if (error || !c) throw error ?? new Error('campus insert failed');
    campusIds.push(c.id as string);
  }

  return { tenantId: tenantId as string, campusIds };
}

async function seedStaffUser(
  tenantId: string,
  role: 'accountant' | 'principal',
  campusIds: string[],
  label: string,
): Promise<{ email: string; password: string }> {
  const admin = adminClient();
  const runId = randomUUID().slice(0, 8);
  const email = `${label}-${runId}@campus-scoping-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: created, error: e1 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e1 || !created.user) throw e1 ?? new Error('user creation failed');

  const { error: e2 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId, app_role: role, full_name: `E2E ${label}` });
  if (e2) throw e2;

  if (campusIds.length > 0) {
    const { error: e3 } = await admin
      .from('user_campus')
      .insert(campusIds.map((campus_id) => ({ user_id: created.user!.id, tenant_id: tenantId, campus_id })));
    if (e3) throw e3;
  }

  return { email, password };
}

async function login(page: import('@playwright/test').Page, email: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
}

test('FR-A12 AC2: an accountant scoped to 4 campuses sees 4 campus options plus "All campuses" on the fee dashboard', async ({
  page,
}) => {
  const { tenantId, campusIds } = await seedTenantWithCampuses(4);
  const { email, password } = await seedStaffUser(tenantId, 'accountant', campusIds, 'accountant');

  await login(page, email, password);

  await page.goto('/fees/reports');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('report-campus-trigger').click();

  await expect(page.getByRole('option')).toHaveCount(5);
  await expect(page.getByTestId('report-campus-option-all')).toHaveText('All campuses');
  for (const campusId of campusIds) {
    await expect(page.getByTestId(`report-campus-option-${campusId}`)).toBeVisible();
  }
});

test('FR-A12 AC4: a staff member with zero campuses assigned sees a "no campus assigned" screen', async ({ page }) => {
  const { tenantId } = await seedTenantWithCampuses(1);
  const { email, password } = await seedStaffUser(tenantId, 'principal', [], 'principal');

  await login(page, email, password);

  await expect(page.getByTestId('no-campus-assigned-heading')).toBeVisible();
  await expect(page.getByTestId('no-campus-assigned-message')).toBeVisible();
});
