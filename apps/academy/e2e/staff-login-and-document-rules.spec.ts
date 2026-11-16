import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR links a login to a staff record and makes a new document required', async ({ page }) => {
  test.setTimeout(120000);
  const { db, mkUser } = await seedHrTenant('staff-link-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const clerk = await mkUser('clerk', 'accountant', { staff: {} });
  await mkUser('teacher', 'subject_teacher');
  await db.from('staff').update({ user_id: null }).eq('id', clerk.staffId!);

  await signInAs(page, hr.email);
  await page.goto(`/staff/${clerk.staffId}`);
  await expect(page.getByTestId('linked-login')).toContainText('Not linked to a login');
  await page.getByTestId('link-login-form').getByLabel('Login').selectOption({ label: 'clerk user (accountant)' });
  await page.getByTestId('link-login-form-submit').click();
  await expect(page.getByTestId('linked-login')).toContainText('Signs in as clerk user (accountant)');
  const { data: linked } = await db.from('staff').select('user_id').eq('id', clerk.staffId!).single();
  expect(linked!.user_id).toBe(clerk.userId);

  await page.goto('/staff/compliance');
  const form = page.getByTestId('document-policy-form');
  await form.getByLabel('Paperwork').selectOption('new');
  await form.getByLabel('Name shown to HR').fill('Degree verification');
  await form.getByLabel('Required').selectOption('yes');
  await page.getByTestId('document-policy-form-submit').click();
  await expect(page.getByTestId('document-policies')).toContainText('Degree verification');
  await expect(page.getByTestId('document-policies').getByText('Degree verification').locator('..')).toContainText('Required');
});
