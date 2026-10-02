import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// Billing period relative to today, not hardcoded 2026-07 — fee_plan.
// effective_from defaults to current_date at enrol_student() time, so a
// hardcoded period before "today" makes generate_challans() find zero
// applicable charges once real time drifts past it. Also searches for a
// period whose due_date (period end + 10 days, FR-K09's own formula) is
// NOT a Sunday — compute_late_fee() shifts a Sunday due date forward by a
// day, which would throw off this test's own exact day-count arithmetic,
// same reasoning as this batch's late_fee_rules.test.sql pgTAP file.
function findSafePeriod(): { period: string; dueDate: string } {
  const now = new Date();
  for (let offset = 0; offset < 12; offset++) {
    const periodStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset, 1));
    const periodEnd = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset + 1, 0));
    const due = new Date(periodEnd.getTime() + 10 * 86400000);
    if (due.getUTCDay() !== 0) {
      return { period: periodStart.toISOString().slice(0, 7), dueDate: due.toISOString().slice(0, 10) };
    }
  }
  throw new Error('no safe (non-Sunday-due) period found in the next 12 months');
}
function addDays(dateStr: string, days: number): string {
  return new Date(new Date(dateStr).getTime() + days * 86400000).toISOString().slice(0, 10);
}

async function seedOwnerWithChallan() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@late-fee-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `late-fee-e2e-${runId}`,
    p_legal_name: `Late Fee E2E School ${runId}`,
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

test('an owner configures a per_day late fee rule and previews the accrued amount on a real challan', async ({ page }) => {
  const { email, password } = await seedOwnerWithChallan();
  const { period, dueDate } = findSafePeriod();
  const asOf = addDays(dueDate, 10);

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
  await page.getByLabel('Name', { exact: true }).fill('Late Fee Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // Generate a challan for the first safe (non-Sunday-due) upcoming period.
  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('challan-period-input').fill(period);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();
  await expect(page.getByTestId('generate-result')).toHaveText('Generated: 1 · Skipped: 0 · Failed: 0');

  // Configure a per_day rule: 3 grace days, PKR 50/day, capped at PKR 1,000.
  await page.goto('/fees/late-fee-rules');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Grace days').fill('3');
  await page.getByLabel('Amount (PKR)').fill('50');
  await page.getByLabel('Cap (PKR, optional)').fill('1000');
  await page.getByTestId('create-late-fee-rule-button').click();
  await expect(page.getByText('Rule created.')).toBeVisible();
  await expect(page.getByText('per day · 3 grace days')).toBeVisible();

  // Preview 10 days after due_date: 10 days late minus 3 grace days = 7
  // chargeable days at PKR 50/day = PKR 350.
  await page.getByTestId('preview-challan-trigger').click();
  await page.getByRole('option').first().click();
  await page.getByTestId('preview-as-of-input').fill(asOf);
  await page.getByTestId('preview-late-fee-button').click();
  await expect(page.getByTestId('late-fee-preview-result')).toHaveText('Late fee: PKR 350');
});
