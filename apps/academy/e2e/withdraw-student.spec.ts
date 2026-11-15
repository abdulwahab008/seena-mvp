import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('an owner withdraws a student, who appears in the withdrawal register, then readmits them', async ({ page }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'withdraw-e2e');
  const { data: student } = await seed.db.from('student').select('id, name_en').eq('tenant_id', seed.tenant).single();
  await signInAs(page, seed.email);

  await page.goto(`/students/${student!.id}`);
  await page.getByTestId('withdraw-student').click();
  await page.getByLabel('Reason').selectOption('relocation');
  await page.getByLabel('Note (optional)').fill('Moved to Lahore');
  await page.getByTestId('confirm-withdraw').click();
  await expect(page.getByText(`${student!.name_en} has been withdrawn.`)).toBeVisible();
  await expect(page.getByTestId('student-left')).toContainText('Left the school');
  await expect(page.getByTestId('withdraw-student')).toHaveCount(0);

  const { data: enrolment } = await seed.db.from('enrolment').select('status, left_on').eq('student_id', student!.id).single();
  expect(enrolment!.status).toBe('left');

  await page.getByRole('link', { name: 'withdrawal register' }).click();
  await expect(page.getByRole('cell', { name: student!.name_en })).toBeVisible();

  await page.goto(`/students/${student!.id}`);
  await page.getByTestId('readmit-student').click();
  await page.getByLabel('Section', { exact: true }).selectOption({ index: 1 });
  await page.getByTestId('confirm-readmit').click();
  await expect(page.getByText(`${student!.name_en} has been readmitted.`)).toBeVisible();
  await expect(page.getByTestId('student-enrolment')).toBeVisible();
  await expect(page.getByTestId('withdraw-student')).toBeVisible();
  const { data: after } = await seed.db.from('enrolment').select('status').eq('student_id', student!.id);
  expect(after!.map((e) => e.status)).toEqual(['active']);
});
