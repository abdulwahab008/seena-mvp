import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { openCashShift } from './support/cash-shift';

test('an owner splits a challan into installments, reads fee analytics, sends fee slips and prints an 80 mm receipt', async ({ page }) => {
  const { db, owner$, email, tenant, challans } = await seedFeesTenant(2, 'fee-extras');
  const [first, second] = challans;
  const { data: enrol } = await db.from('enrolment').select('student_id').eq('id', first!.enrolment_id).single();
  const { data: father } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Father', phone_e164: '+923006660000' }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrol!.student_id, guardian_id: father!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/fees/installments');
  await page.getByLabel('Challan number').fill(first!.challan_no);
  await page.getByLabel('Installments').fill('3');
  await page.getByRole('button', { name: 'Split into installments' }).click();
  await expect(page.getByText('Challan split into 3 monthly installments.')).toBeVisible();
  await expect(page.getByTestId('installment-row')).toHaveCount(3);

  const paid = await owner$.rpc('record_payment', { p_enrolment_id: second!.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash', p_reference_no: 'analytics' });
  expect(paid.error).toBeNull();
  await page.goto('/fees/analytics');
  await expect(page.getByTestId('fee-kpi-collected')).toHaveText('PKR 8,500.00');
  await page.getByRole('button', { name: 'Send fee slips' }).click();
  await expect(page.getByText('Queued 1 fee reminder.')).toBeVisible();

  await openCashShift(page);
  await page.getByTestId('counter-challan-no-input').fill(first!.challan_no);
  await page.getByTestId('counter-lookup-button').click();
  await expect(page.getByTestId('counter-lookup-result')).toBeVisible();
  await page.getByTestId('counter-amount-input').fill('2000');
  await page.getByTestId('counter-collect-button').click();
  await page.getByTestId('counter-print-button').click();
  await expect(page.getByTestId('thermal-print-button')).toBeVisible();
  await expect(page.getByTestId('thermal-receipt')).toContainText('PKR 2,000.00');
  await page.emulateMedia({ media: 'print' });
  await expect(page.getByTestId('thermal-receipt')).toBeVisible();
});
