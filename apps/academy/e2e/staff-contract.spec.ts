import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR records a probation contract, confirms it, then revises the salary with a new contract', async ({ page }) => {
  test.setTimeout(120000);
  const { db, mkUser } = await seedHrTenant('contract-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: { doj: '2026-01-01' } });
  await signInAs(page, hr.email);

  await page.goto(`/staff/${teacher.staffId}`);
  const card = page.getByTestId('contract-card');
  await expect(card).toContainText('No contract on file');
  const form = page.getByTestId('contract-form');
  await form.getByLabel('Type').selectOption('probation');
  await form.getByLabel('Starts on').fill('2026-01-01');
  await form.getByLabel('Gross salary per month (PKR)').fill('80000');
  await form.getByLabel('Notice period (days)').fill('30');
  await page.getByTestId('contract-form-submit').click();
  await expect(page.getByTestId('contract-row')).toHaveCount(1);
  await expect(page.getByTestId('contract-row')).toContainText('80,000');

  await page.getByTestId('confirm-probation').click();
  await expect(page.getByTestId('contract-row')).toContainText('Confirmed');

  await form.getByLabel('Type').selectOption('permanent');
  await form.getByLabel('Starts on').fill('2026-07-01');
  await form.getByLabel('Gross salary per month (PKR)').fill('90000');
  await page.getByTestId('contract-form-submit').click();
  await expect(page.getByTestId('contract-row')).toHaveCount(2);
  await expect(page.getByTestId('contract-row').first()).toContainText('Current');

  const { data } = await db.from('staff_contract').select('contract_type, end_date, staff_contract_pay(gross_salary)').eq('staff_id', teacher.staffId!).order('start_date');
  expect(data!.map((c) => [c.contract_type, c.end_date])).toEqual([
    ['probation', '2026-06-30'],
    ['permanent', null],
  ]);
});
