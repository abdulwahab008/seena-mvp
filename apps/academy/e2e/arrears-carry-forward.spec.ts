import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// Billing periods relative to today's month, not hardcoded 2026-07/08/09 —
// fee_plan.effective_from defaults to current_date at enrol_student() time,
// so a hardcoded period before "today" makes generate_challans() find zero
// applicable charges once real time drifts past it. Same fix already
// applied to this suite's 4 pgTAP equivalents (see supabase/tests/database/
// arrears_carry_forward.test.sql's own header) and to the fee generated-
// result assertion in late-fee-rules.spec.ts.
function monthOffset(offset: number): string {
  const now = new Date();
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + offset, 1));
  return d.toISOString().slice(0, 7);
}
const MONTH1 = monthOffset(0);
const MONTH2 = monthOffset(1);
const MONTH3 = monthOffset(2);

async function seedOwnerWithPublishedStructure() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@arrears-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `arrears-e2e-${runId}`,
    p_legal_name: `Arrears E2E School ${runId}`,
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

  // The AC's 8,500-owed / 8,000-charged pair needs two different amounts in
  // two consecutive months off one snapshot plan, so an annual head billed
  // in MONTH1 only rides on top of the flat monthly tuition: MONTH1 =
  // 800,000 + 50,000 = 850,000 paisa, MONTH2 = 800,000 paisa.
  const { data: annual, error: e7 } = await admin
    .from('fee_head')
    .insert({
      tenant_id: tenantId as string,
      code: 'ANNUAL',
      name_en: 'Annual Fund',
      name_ur: 'سالانہ فنڈ',
      is_mandatory: false,
      default_frequency: 'annual',
    })
    .select('id')
    .single();
  if (e7) throw e7;

  const { error: e8 } = await admin.from('fee_structure_line').insert([
    {
      structure_id: structure!.id,
      class_id: classLevel!.id,
      fee_head_id: tuition!.id,
      amount_paisa: 800000,
      frequency: 'monthly',
      // Spelled out rather than left to the column default: a multi-row
      // PostgREST insert unions the keys across all rows, so a key absent
      // from one object arrives as an explicit NULL, not "use the default".
      billing_month_mask: 4095,
    },
    {
      structure_id: structure!.id,
      class_id: classLevel!.id,
      fee_head_id: annual!.id,
      amount_paisa: 50000,
      frequency: 'annual',
      billing_month_mask: 1 << (Number(MONTH1.slice(5, 7)) - 1),
    },
  ]);
  if (e8) throw e8;

  return { email, password };
}

test('an unpaid challan carries forward as arrears on the next month, and clears once paid', async ({ page }) => {
  const { email, password } = await seedOwnerWithPublishedStructure();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Arrears Carry Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentUrl = page.url();

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');

  // Month 1 is left unpaid on purpose.
  await page.getByTestId('challan-period-input').fill(MONTH1);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();

  // Month 2's challan shows the carried-forward arrears from month 1.
  await page.getByTestId('challan-period-input').fill(MONTH2);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();

  const month2Row = page.locator('[data-testid^="challan-row-"]').filter({ hasText: `${MONTH2}-01` });
  await expect(month2Row.getByTestId(/challan-arrears-/)).toContainText('Current PKR 8,000');
  await expect(month2Row.getByTestId(/challan-arrears-/)).toContainText('Arrears PKR 8,500');
  await expect(month2Row.getByTestId(/challan-net-/)).toContainText('Net PKR 16,500');

  // Pay the full arrears-inclusive net payable — it reaches back and
  // settles July too, via the ordinary payment waterfall.
  await page.goto(studentUrl);
  await page.waitForLoadState('networkidle');
  await page.getByTestId('payment-amount-input').fill('16500');
  await page.getByTestId('record-payment-button').click();
  await expect(page.getByText('Payment recorded and allocated.')).toBeVisible();
  await expect(page.getByTestId('ledger-balance')).toHaveText('Balance: PKR 0');

  // Month 3 now shows zero arrears.
  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('challan-period-input').fill(MONTH3);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();

  const month3Row = page.locator('[data-testid^="challan-row-"]').filter({ hasText: `${MONTH3}-01` });
  await expect(month3Row.getByTestId(/challan-arrears-/)).toHaveCount(0);
  await expect(month3Row.getByTestId(/challan-net-/)).toContainText('Net PKR 8,000');
});
