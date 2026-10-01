import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K28: a deposit is recorded, the no-dues checklist is cleared, the refund is approved and disbursed.

test('a deposit is refunded once every no-dues item is cleared', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, owner$, tenant, campusId, challans } = await seedFeesTenant(1, 'nodues-e2e');
  const challan = challans[0]!;
  const { error: payError } = await owner$.rpc('record_payment', { p_enrolment_id: challan.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash' });
  expect(payError).toBeNull();
  const { data: enrol } = await db.from('enrolment').select('student_id').eq('id', challan.enrolment_id).single();
  const { data: student } = await db.from('student').select('gr_number').eq('id', enrol!.student_id).single();

  const acctEmail = `acct-${tenant.slice(0, 8)}@nodues-e2e.test`;
  const { data: acct } = await db.auth.admin.createUser({ email: acctEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: acct.user!.id, tenant_id: tenant, app_role: 'accountant', full_name: 'Seed Accountant' });
  await db.from('user_campus').insert({ user_id: acct.user!.id, tenant_id: tenant, campus_id: campusId });
  const acct$ = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321', process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  await acct$.auth.signInWithPassword({ email: acctEmail, password: SEED_PASSWORD });
  const { error: buildError } = await acct$.rpc('build_no_dues_checklist', { p_enrolment_id: challan.enrolment_id });
  expect(buildError).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/no-dues');
  await page.getByLabel('GR number').first().fill(student!.gr_number);
  await page.getByLabel('Amount (PKR)').fill('5000');
  await page.getByLabel('Received on').fill('2021-03-01');
  await page.getByTestId('record-deposit').click();
  await expect(page.getByTestId('deposit-line')).toContainText('Deposit PKR 5,000 — held');

  for (const domain of ['library', 'transport', 'hostel', 'inventory']) {
    await page.getByTestId(`clear-${domain}`).first().click();
    await expect(page.getByTestId(`clear-${domain}`)).toHaveCount(0);
  }
  await page.getByTestId('approve-refund').click();
  await expect(page.getByTestId('deposit-line')).toContainText('refund approved');
  await page.locator('select').last().selectOption('cash');
  await page.getByTestId('disburse-refund').click();
  await expect(page.getByTestId('deposit-line')).toContainText('refunded');
});
