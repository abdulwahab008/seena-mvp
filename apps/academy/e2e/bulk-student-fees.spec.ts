import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

test('an owner changes the tuition fee for two of three students in one step', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(3, 'bulkfee-e2e');
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto(`/fees/student-fees?cls=${level!.id}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByText('3 students')).toBeVisible();
  await expect(page.getByRole('cell', { name: 'PKR 8,500' })).toHaveCount(3);

  await page.getByRole('checkbox', { name: 'Select bulkfee-e2e Kid 1' }).check();
  await page.getByRole('checkbox', { name: 'Select bulkfee-e2e Kid 2' }).check();
  await page.getByLabel('New amount (PKR)').fill('4000');
  await page.getByLabel('Reason').fill('Staff children');
  await expect(page.getByRole('checkbox', { name: 'Approve now' })).toBeChecked();
  await page.getByRole('button', { name: 'Change fee for 2 selected' }).click();
  await expect(page.getByText('Fee changed for 2 students.')).toBeVisible();

  await expect(page.getByRole('cell', { name: 'PKR 4,000' })).toHaveCount(2);
  await expect(page.getByRole('cell', { name: 'PKR 8,500' })).toHaveCount(1);

  // Sent for approval instead: the change waits, then is approved from the same page.
  await page.getByRole('checkbox', { name: 'Select bulkfee-e2e Kid 3' }).check();
  await page.getByLabel('New amount (PKR)').fill('6000');
  await page.getByLabel('Reason').fill('Hardship');
  await page.getByRole('checkbox', { name: 'Approve now' }).uncheck();
  await page.getByRole('button', { name: 'Change fee for 1 selected' }).click();
  await expect(page.getByText('Sent 1 changes for approval.')).toBeVisible();
  await expect(page.getByText('PKR 6,000 awaiting approval')).toBeVisible();

  await page.getByRole('checkbox', { name: 'Select bulkfee-e2e Kid 3' }).check();
  await page.getByRole('button', { name: 'Approve selected' }).click();
  await expect(page.getByText('Approved 1 changes.')).toBeVisible();
  await expect(page.getByRole('cell', { name: 'PKR 6,000' })).toHaveCount(1);
});
