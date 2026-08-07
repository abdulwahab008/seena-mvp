import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@bell-template-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `bell-template-e2e-${runId}`,
    p_legal_name: `Bell Template E2E School ${runId}`,
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

async function fillSegment(page: import('@playwright/test').Page, index: number, kind: string, start: string, end: string) {
  await page.getByTestId(`segment-kind-trigger-${index}`).click();
  await page.getByRole('option', { name: kind, exact: true }).click();
  await page.getByTestId(`segment-start-${index}`).fill(start);
  await page.getByTestId(`segment-end-${index}`).fill(end);
}

test('an owner builds a bell template, sees correct period numbering, and overlap/duplicate/default rules hold', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/bell-templates');
  await page.waitForLoadState('networkidle');

  // AC: no default template yet for either shift.
  await expect(page.getByTestId('no-default-banner')).toContainText('MORNING');
  await expect(page.getByTestId('no-default-banner')).toContainText('AFTERNOON');

  // 4 segments: assembly, a teaching period, a break, another teaching
  // period — the break must NOT consume a period number.
  await page.getByLabel('Code').fill('REGULAR');
  await page.getByLabel('Name').fill('Regular Morning');
  await fillSegment(page, 0, 'ASSEMBLY', '07:45', '08:00');
  await page.getByTestId('add-segment-button').click();
  await fillSegment(page, 1, 'TEACHING', '08:00', '08:40');
  await page.getByTestId('add-segment-button').click();
  await fillSegment(page, 2, 'BREAK', '08:40', '08:50');
  await page.getByTestId('add-segment-button').click();
  await fillSegment(page, 3, 'TEACHING', '08:50', '09:30');
  await page.getByRole('checkbox', { name: 'Set as default for this campus + shift' }).check();
  await page.getByTestId('create-bell-template-button').click();

  await expect(page.getByText('Regular Morning created.')).toBeVisible();
  const row = page.getByTestId('bell-template-row-REGULAR');
  await expect(row).toBeVisible();
  // AC: teaching segments are numbered Period 1, Period 2 — not segment 2/4.
  await expect(row).toContainText('Period 1 — 08:00–08:40');
  await expect(row).toContainText('Period 2 — 08:50–09:30');
  await expect(row).toContainText('ASSEMBLY — 07:45–08:00');
  await expect(row).toContainText('BREAK — 08:40–08:50');
  await expect(row.getByTestId(/is-default-/)).toBeVisible();

  // AC: nominating a default clears the MORNING gap in the banner but
  // AFTERNOON still has none.
  await expect(page.getByTestId('no-default-banner')).not.toContainText('MORNING');
  await expect(page.getByTestId('no-default-banner')).toContainText('AFTERNOON');

  // AC: a duplicate code for the same campus+shift is rejected.
  await page.getByLabel('Code').fill('REGULAR');
  await page.getByLabel('Name').fill('Duplicate Attempt');
  await fillSegment(page, 0, 'TEACHING', '14:00', '14:40');
  await page.getByTestId('create-bell-template-button').click();
  await expect(page.getByText('A template with this code already exists for this campus and shift.')).toBeVisible();

  // AC: overlapping segments are rejected and the offending pair is named.
  await page.getByLabel('Code').fill('OVERLAP');
  await page.getByLabel('Name').fill('Overlap Template');
  await fillSegment(page, 0, 'TEACHING', '08:00', '08:40');
  await page.getByTestId('add-segment-button').click();
  await fillSegment(page, 1, 'TEACHING', '09:20', '10:10');
  await page.getByTestId('add-segment-button').click();
  await fillSegment(page, 2, 'TEACHING', '10:00', '10:40');
  await page.getByTestId('create-bell-template-button').click();
  await expect(page.getByText('Segments 2 and 3 overlap.')).toBeVisible();
  await expect(page.getByTestId('bell-template-row-OVERLAP')).not.toBeVisible();
});

test('an owner shortens Friday with a calendar rule, and a duplicate weekday+precedence rule is rejected', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/bell-templates');
  await page.waitForLoadState('networkidle');

  // Default 8-period regular template.
  await page.getByLabel('Code').fill('REGULAR');
  await page.getByLabel('Name').fill('Regular Morning');
  await fillSegment(page, 0, 'TEACHING', '08:00', '08:40');
  await page.getByRole('checkbox', { name: 'Set as default for this campus + shift' }).check();
  await page.getByTestId('create-bell-template-button').click();
  await expect(page.getByText('Regular Morning created.')).toBeVisible();

  // Shortened Friday template.
  await page.getByLabel('Code').fill('FRIDAY');
  await page.getByLabel('Name').fill('Friday Shortened');
  await fillSegment(page, 0, 'TEACHING', '08:00', '08:30');
  await page.getByTestId('create-bell-template-button').click();
  await expect(page.getByText('Friday Shortened created.')).toBeVisible();

  await expect(page.getByText('No calendar rules yet')).toBeVisible();

  // AC: nominate Friday to resolve to the shortened template.
  await page.getByTestId('rule-weekday-trigger').click();
  await page.getByRole('option', { name: 'Friday', exact: true }).click();
  await page.getByTestId('rule-template-trigger').click();
  await page.getByRole('option', { name: 'Friday Shortened (FRIDAY)' }).click();
  await page.getByLabel('Note (optional)').fill('Jumma break');
  await page.getByTestId('create-bell-rule-button').click();
  await expect(page.getByText('Rule created.')).toBeVisible();

  const ruleRow = page.locator('[data-testid^="bell-rule-row-"]');
  await expect(ruleRow).toBeVisible();
  await expect(ruleRow).toContainText('Friday');
  await expect(ruleRow).toContainText('Friday Shortened (FRIDAY)');
  await expect(ruleRow).toContainText('precedence 50');

  // AC: a second rule at the same weekday + precedence is ambiguous and rejected.
  await page.getByTestId('rule-weekday-trigger').click();
  await page.getByRole('option', { name: 'Friday', exact: true }).click();
  await page.getByTestId('rule-template-trigger').click();
  await page.getByRole('option', { name: 'Regular Morning (REGULAR)' }).click();
  await page.getByTestId('create-bell-rule-button').click();
  await expect(page.getByText('A rule already exists for this weekday and precedence.')).toBeVisible();

  // Removing the rule reverts to "no calendar rules".
  await ruleRow.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByText('Rule removed.')).toBeVisible();
  await expect(page.getByText('No calendar rules yet')).toBeVisible();
});
