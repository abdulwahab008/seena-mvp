import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@ramadan-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `ramadan-e2e-${runId}`,
    p_legal_name: `Ramadan E2E School ${runId}`,
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

async function createTemplate(page: import('@playwright/test').Page, code: string, name: string, start: string, end: string, isDefault: boolean) {
  await page.getByLabel('Code').fill(code);
  await page.getByLabel('Name').fill(name);
  await page.getByTestId('segment-kind-trigger-0').click();
  await page.getByRole('option', { name: 'TEACHING', exact: true }).click();
  await page.getByTestId('segment-start-0').fill(start);
  await page.getByTestId('segment-end-0').fill(end);
  if (isDefault) await page.getByRole('checkbox', { name: 'Set as default for this campus + shift' }).check();
  await page.getByTestId('create-bell-template-button').click();
  await expect(page.getByText(`${name} created.`)).toBeVisible();
}

test('a Principal activates a Ramadan window, is blocked from an overlapping one, and corrects the dates after the moon sighting', async ({
  page,
}) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/bell-templates');
  await page.waitForLoadState('networkidle');

  await createTemplate(page, 'REGULAR', 'Regular Morning', '08:00', '08:40', true);
  await createTemplate(page, 'RAMADAN', 'Ramadan Day', '08:00', '08:30', false);

  await expect(page.getByTestId('no-date-rules')).toBeVisible();

  // AC: the Principal enters the window by hand — Ramadan dates are not
  // knowable in advance.
  await page.getByTestId('override-template-trigger').click();
  await page.getByRole('option', { name: 'Ramadan Day (RAMADAN)' }).click();
  await page.getByTestId('override-date-from').fill('2027-02-18');
  await page.getByTestId('override-date-to').fill('2027-03-19');
  await page.getByLabel('Ramadan note').fill('Ramadan 1448');
  await page.getByTestId('create-date-rule-button').click();
  await expect(page.getByText('Override activated.')).toBeVisible();

  const overrideRow = page.locator('[data-testid^="date-rule-row-"]');
  await expect(overrideRow).toContainText('2027-02-18 → 2027-03-19');
  await expect(overrideRow).toContainText('Ramadan Day (RAMADAN)');
  // Above FR-F02's weekday rules, so a Ramadan Friday takes Ramadan timings.
  await expect(overrideRow).toContainText('precedence 100');

  // AC5: a second override of the same precedence overlapping the first
  // is genuinely ambiguous and is refused.
  await page.getByTestId('override-template-trigger').click();
  await page.getByRole('option', { name: 'Regular Morning (REGULAR)' }).click();
  await page.getByTestId('override-date-from').fill('2027-03-01');
  await page.getByTestId('override-date-to').fill('2027-04-01');
  await page.getByTestId('create-date-rule-button').click();
  await expect(page.getByText('Another override of the same precedence already covers part of this date range.')).toBeVisible();

  // AC2: the sighting shifts the start by a day and the Principal
  // corrects the range the next morning.
  await overrideRow.getByRole('button', { name: 'Correct dates' }).click();
  const ruleId = (await overrideRow.getAttribute('data-testid'))!.replace('date-rule-row-', '');
  await page.getByTestId(`correct-date-from-${ruleId}`).fill('2027-02-19');
  await page.getByTestId(`save-dates-${ruleId}`).click();
  await expect(page.getByText('Dates corrected.')).toBeVisible();
  await expect(overrideRow).toContainText('2027-02-19 → 2027-03-19');

  await overrideRow.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByText('Override removed.')).toBeVisible();
  await expect(page.getByTestId('no-date-rules')).toBeVisible();
});
