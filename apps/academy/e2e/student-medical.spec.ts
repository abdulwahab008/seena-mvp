import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('an owner records a student\'s medical details and sees the critical allergy warning', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'medical-e2e');
  const { data: student } = await seed.db.from('student').select('id').eq('tenant_id', seed.tenant).single();
  await signInAs(page, seed.email);

  await page.goto(`/students/${student!.id}`);
  await expect(page.getByTestId('student-medical')).toContainText('No medical details recorded.');
  await page.getByTestId('edit-medical').click();
  await page.getByLabel('Allergies').fill('Peanuts, dust');
  await page.getByLabel('Medicines').fill('Inhaler');
  await page.getByLabel('Critical allergy').check();
  await page.getByLabel('Emergency contact name').fill('Asif Khan');
  await page.getByLabel('Emergency contact phone').fill('0300-1234567');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Medical details saved.')).toBeVisible();

  const medical = page.getByTestId('student-medical');
  await expect(medical).toContainText('Critical allergy');
  await expect(medical).toContainText('Peanuts, dust');
  await expect(medical).toContainText('Asif Khan · 0300-1234567');
  const { data: row } = await seed.db.from('student_medical').select('allergies, has_critical_allergy').eq('student_id', student!.id).single();
  expect(row).toEqual({ allergies: ['Peanuts', 'dust'], has_critical_allergy: true });
});
