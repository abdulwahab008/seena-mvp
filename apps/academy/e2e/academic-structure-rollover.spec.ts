import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSectionAndSecondSession() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@rollover-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `rollover-e2e-${runId}`,
    p_legal_name: `Rollover E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus, error: eCampus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  if (eCampus || !campus) throw eCampus ?? new Error('campus not seeded');
  const { data: fromSession, error: eFromSession } = await admin
    .from('academic_session')
    .select('id, name')
    .eq('tenant_id', tenantId as string)
    .single();
  if (eFromSession || !fromSession) throw eFromSession ?? new Error('session not seeded');
  const { data: class9, error: eClass9 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '9')
    .single();
  if (eClass9 || !class9) throw eClass9 ?? new Error('class level not seeded');

  // Seeded directly (not via create_section's RPC), same as other e2e
  // specs: its own role/campus checks read JWT claims a service-role call
  // never carries.
  const { error: e4 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus.id, session_id: fromSession.id, class_level_id: class9.id, name: 'A', capacity: 40 });
  if (e4) throw e4;

  const nextYearStart = new Date();
  nextYearStart.setFullYear(nextYearStart.getFullYear() + 1);
  const nextYearEnd = new Date(nextYearStart);
  nextYearEnd.setFullYear(nextYearEnd.getFullYear() + 1);
  nextYearEnd.setDate(nextYearEnd.getDate() - 1);
  const { data: toSession, error: e5 } = await admin
    .from('academic_session')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus.id,
      name: 'Next Session',
      starts_on: nextYearStart.toISOString().slice(0, 10),
      ends_on: nextYearEnd.toISOString().slice(0, 10),
    })
    .select('id, name')
    .single();
  if (e5 || !toSession) throw e5 ?? new Error('to-session creation failed');

  return { email, password, fromSessionName: fromSession.name as string, toSessionName: toSession.name as string };
}

test('an owner previews a session rollover, then confirms it, and a second confirm reports everything skipped', async ({ page }) => {
  const { email, password, fromSessionName, toSessionName } = await seedOwnerWithSectionAndSecondSession();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/rollover');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('rollover-campus-trigger').click();
  await page.getByRole('option').first().click();
  await page.getByTestId('rollover-from-session-trigger').click();
  await page.getByRole('option', { name: fromSessionName, exact: true }).click();
  await page.getByTestId('rollover-to-session-trigger').click();
  await page.getByRole('option', { name: toSessionName, exact: true }).click();

  // AC: a preview reports what would happen and writes nothing.
  await page.getByRole('button', { name: 'Preview' }).click();
  await expect(page.getByText('Preview ready — nothing has been saved yet.')).toBeVisible();
  await expect(page.getByTestId('rollover-summary')).toContainText('Preview');
  await expect(page.getByTestId('rollover-sections-summary')).toHaveText('1 created, 0 skipped');

  // AC: confirming applies it for real.
  await page.getByRole('button', { name: 'Confirm rollover' }).click();
  await expect(page.getByText('Rollover applied.')).toBeVisible();
  await expect(page.getByTestId('rollover-summary')).toContainText('Applied');
  await expect(page.getByTestId('rollover-sections-summary')).toHaveText('1 created, 0 skipped');

  // AC: running it again against the same target reports it all skipped —
  // no duplicates.
  await page.getByRole('button', { name: 'Confirm rollover' }).click();
  await expect(page.getByTestId('rollover-sections-summary')).toHaveText('0 created, 1 skipped');
});
