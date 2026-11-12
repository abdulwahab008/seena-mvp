import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

test('clicking a class on the students dashboard lists that class', async ({ page }) => {
  test.setTimeout(120000);
  const { email } = await seedFeesTenant(2, 'studash-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students/dashboard');
  await page.getByRole('link', { name: /Class 1\s*2/ }).click();
  await expect(page).toHaveURL(/\/students\?cls=c:/);
  await expect(page.getByText('studash-e2e Kid 1')).toBeVisible();
  await expect(page.getByText('studash-e2e Kid 2')).toBeVisible();
  await page.goto('/students/dashboard');
  await page.screenshot({ path: process.env.SHOT ?? 'test-results/students-dashboard.png', fullPage: true });
});
