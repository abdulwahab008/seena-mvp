import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T14: audit trail export, exercised end to end through the real UI —
// an Owner requests an export covering a wide date range and the
// 'app_user' entity (which their own account's own creation already
// audited), generates it, and gets a downloadable, row-counted result plus
// a "Recent exports" entry with a working link.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@audit-export-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `audit-export-e2e-${runId}`,
    p_legal_name: `Audit Export E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  // This INSERT is itself an audited write (app_user_audit) — exactly the
  // row the test below expects the export to contain.
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { email, password };
}

test('an owner requests an audit trail export, generates it, and gets a downloadable, row-counted result', async ({ page }) => {
  const { email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/audit-export');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Audit trail export' })).toBeVisible();

  // A wide range around "now" — occurred_at is clock_timestamp() at
  // insert time, not a fixed seed date, so the range has to bracket
  // whenever this test actually runs rather than a hardcoded day.
  await page.getByTestId('export-from-input').fill('2020-01-01');
  await page.getByTestId('export-to-input').fill('2030-12-31');
  await page.getByTestId('export-entity-app_user').locator('input[type="checkbox"]').check();

  await page.getByTestId('export-run-button').click();

  const result = page.getByTestId('export-latest-result');
  await expect(result).toBeVisible();
  await expect(result).toContainText(/row/);
  await expect(result).not.toContainText('0 rows');

  const downloadLink = page.getByTestId('export-download-link');
  await expect(downloadLink).toBeVisible();
  const href = await downloadLink.getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);

  // AC4's own "signed download link" — a direct fetch of the href (no
  // browser session at all) must actually return the export file.
  const downloadResponse = await page.request.get(href!);
  expect(downloadResponse.ok()).toBe(true);
  const body = await downloadResponse.text();
  expect(body.length).toBeGreaterThan(0);
  const [firstLineText] = body.trim().split('\n');
  const firstLine = JSON.parse(firstLineText ?? '{}');
  expect(firstLine.table_name).toBe('app_user');

  // AC1: the export lists in "Recent exports", newest first.
  const jobCard = page.getByTestId(/^export-job-/).first();
  await expect(jobCard).toBeVisible();
  await expect(jobCard).toContainText('app_user');
  await expect(jobCard).toContainText('Completed');
  await expect(jobCard.getByRole('link', { name: 'Download' })).toBeVisible();
});
