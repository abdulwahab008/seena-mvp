import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K27: a settlement is previewed and proposed from the screen and waits for approval.

test('an owner previews and proposes a withdrawal settlement', async ({ page }) => {
  test.setTimeout(90000);
  const { db, email, owner$, challans } = await seedFeesTenant(1, 'settle-e2e');
  const challan = challans[0]!;
  const { error } = await owner$.rpc('record_payment', { p_enrolment_id: challan.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash' });
  expect(error).toBeNull();
  const { data: enrol } = await db.from('enrolment').select('student_id').eq('id', challan.enrolment_id).single();
  const { data: student } = await db.from('student').select('gr_number').eq('id', enrol!.student_id).single();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/settlements');
  await page.getByLabel('GR number').fill(student!.gr_number);
  await page.getByLabel('Leaving date').fill(new Date().toISOString().slice(0, 10));
  await page.getByTestId('settlement-preview-btn').click();
  await expect(page.getByTestId('settlement-preview')).toContainText('Refund payable');

  await page.getByTestId('settlement-propose').click();
  await expect(page.getByTestId('settlement-row')).toHaveCount(1);
  await expect(page.getByTestId('settlement-row')).toContainText('pending');
});
