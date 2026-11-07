import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR records training for CPD, and a teacher raises a grievance HR resolves', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { mkUser, owner } = await seedHrTenant('cpd-e2e');
  const teacher = await mkUser('teach', 'subject_teacher', { staff: { doj: '2025-01-01' } });
  const hr = await mkUser('hr', 'hr_manager', { staff: { doj: '2025-01-01' } });
  expect(owner.email).toBeTruthy();

  const tctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const tp = await tctx.newPage();
  await signInAs(tp, teacher.email);
  await tp.goto('/staff/grievances');
  await tp.getByLabel('Subject').fill('Too many periods');
  await tp.getByLabel('What is the problem?').fill('I teach 38 periods a week.');
  await tp.getByRole('button', { name: 'Send to HR' }).click();
  await expect(tp.getByTestId('grievance-status')).toHaveText('Open');

  await signInAs(page, hr.email);
  await page.goto('/staff/training');
  await page.getByLabel('Program').fill('Child safeguarding');
  await page.getByLabel('Hours').fill('6');
  await page.locator('label', { hasText: teacher.fullName }).click();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('cpd-row').filter({ hasText: teacher.fullName })).toContainText('6');

  await page.goto('/staff/grievances');
  const row = page.getByTestId('grievance-row').filter({ hasText: 'Too many periods' });
  await row.getByRole('button', { name: 'Resolve' }).click();
  await page.getByLabel(/Outcome/).fill('Timetable rebalanced to 32 periods.');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('grievance-status')).toHaveText('Resolved');

  await tp.reload();
  await expect(tp.getByTestId('grievance-row')).toContainText('Timetable rebalanced to 32 periods.');
  await tctx.close();
});
