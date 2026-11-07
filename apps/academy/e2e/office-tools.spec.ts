import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the office keeps a shared task list and phone book', async ({ page }) => {
  const { owner, mkUser } = await seedHrTenant('office-tools');
  await mkUser('clerk', 'receptionist');
  await signInAs(page, owner.email);

  await page.goto('/office');
  await page.getByLabel('Task').fill('Order chalk for Class 5');
  await page.getByLabel('For').selectOption({ label: 'clerk user' });
  await page.getByRole('button', { name: 'Add task' }).click();
  const task = page.getByTestId('team-task').filter({ hasText: 'Order chalk' });
  await expect(task).toContainText('For clerk user');
  await task.getByRole('button', { name: 'Done' }).click();
  await expect(page.getByTestId('team-task')).toHaveCount(0);

  await page.getByLabel('Name').fill('Dr Asif');
  await page.getByLabel('Organisation').fill('City Clinic');
  await page.getByLabel('Category').selectOption('medical');
  await page.getByLabel('Phone').fill('042-1234567');
  await page.getByRole('button', { name: 'Add contact' }).click();
  await expect(page.getByTestId('office-contact')).toContainText('City Clinic');
  await page.getByLabel('Search contacts').fill('clinic');
  await page.getByLabel('Search contacts').press('Enter');
  await expect(page.getByTestId('office-contact')).toHaveCount(1);
});
