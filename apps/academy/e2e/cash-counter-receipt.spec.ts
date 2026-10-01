import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// The billing period is today's month, not a hardcoded 2026-08: the fee plan's
// effective_from defaults to current_date at enrol time, so a period that ends
// before "today" finds zero applicable charges once real time drifts past it
// (same fix as arrears-carry-forward.spec.ts).
const BILLING_PERIOD = new Date().toISOString().slice(0, 7);

async function seedOwnerWithPublishedStructure() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@cash-counter-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `cash-counter-e2e-${runId}`,
    p_legal_name: `Cash Counter E2E School ${runId}`,
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

test('an accountant collects a cash payment at the counter and prints a receipt, with a reprint watermarked duplicate', async ({
  page,
}) => {
  const { email, password } = await seedOwnerWithPublishedStructure();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Cash Counter Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('challan-period-input').fill(BILLING_PERIOD);
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();

  const challanRow = page.locator('[data-testid^="challan-row-"]');
  const challanRowText = await challanRow.first().innerText();
  const challanNo = challanRowText.split('·')[0]!.trim();

  await page.goto('/fees/counter');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('counter-challan-no-input').fill(challanNo);
  await page.getByTestId('counter-lookup-button').click();

  const lookupResult = page.getByTestId('counter-lookup-result');
  await expect(lookupResult).toContainText('Cash Counter Child');
  await expect(lookupResult).toContainText('Outstanding PKR 5,000');
  // AC: the amount field is pre-filled with the net payable.
  await expect(page.getByTestId('counter-amount-input')).toHaveValue('5000');

  await page.getByTestId('counter-collect-button').click();
  await expect(page.getByText('Payment collected.')).toBeVisible();

  await page.getByTestId('counter-print-button').click();
  const printResult = page.getByTestId('counter-print-result');
  await expect(printResult).toContainText('Cash Counter Child');
  await expect(printResult).toContainText('Rupees Five Thousand Only');
  await expect(printResult).toContainText('Outstanding after this payment: PKR 0');
  await expect(page.getByTestId('counter-duplicate-watermark')).toHaveCount(0);

  // AC: printing the same receipt again is watermarked DUPLICATE.
  await page.getByTestId('counter-print-button').click();
  await expect(page.getByTestId('counter-duplicate-watermark')).toContainText('DUPLICATE');
});
