import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithPublishedStructure() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@challan-gen-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `challan-gen-e2e-${runId}`,
    p_legal_name: `Challan Gen E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 5,
  });
  if (e4) throw e4;

  const { data: tuition, error: e5 } = await admin
    .from('fee_head')
    .insert({
      tenant_id: tenantId as string,
      code: 'TUITION',
      name_en: 'Tuition Fee',
      name_ur: 'فیس تعلیم',
      is_mandatory: true,
      default_frequency: 'monthly',
    })
    .select('id')
    .single();
  if (e5) throw e5;

  const { data: structure, error: e6 } = await admin
    .from('fee_structure')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      status: 'published',
      published_at: new Date().toISOString(),
    })
    .select('id')
    .single();
  if (e6) throw e6;

  const { error: e7 } = await admin.from('fee_structure_line').insert({
    structure_id: structure!.id,
    class_id: classLevel!.id,
    fee_head_id: tuition!.id,
    amount_paisa: 500000,
    frequency: 'monthly',
  });
  if (e7) throw e7;

  return { email, password };
}

test('an owner generates monthly challans for enrolled students, and a re-run is a no-op', async ({ page }) => {
  const { email, password } = await seedOwnerWithPublishedStructure();

  // A freshly built fee plan line takes effect today (effective_from defaults to
  // current_date), so the billing month under test must be the current one — a
  // hard-coded past month legitimately has nothing to charge and is skipped.
  const period = new Date().toISOString().slice(0, 7);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Admit a student and enrol into the section — enrolling auto-builds a
  // fee plan (FR-K04) against the published TUITION structure line.
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Challan Gen Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('challan-period-input').fill(period);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();
  await expect(page.getByTestId('generate-result')).toHaveText('Generated: 1 · Skipped: 0 · Failed: 0');

  const challanRow = page.locator('[data-testid^="challan-row-"]');
  await expect(challanRow).toHaveCount(1);
  await expect(challanRow).toContainText('Net PKR 5,000');
  await expect(challanRow).toContainText(`${period}-01`);

  // Re-running the same month is fully idempotent: the existing challan is
  // reported skipped, and no second row appears.
  await page.getByTestId('challan-period-input').fill(period);
  await page.getByTestId('generate-button').click();
  await expect(page.getByTestId('generate-result')).toHaveText('Generated: 0 · Skipped: 1 · Failed: 0');
  await expect(page.locator('[data-testid^="challan-row-"]')).toHaveCount(1);
});
