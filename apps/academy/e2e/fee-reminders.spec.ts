import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-K26: the ladder is created from the screen and rungs can be paused.

test('an owner creates the default reminder ladder and pauses a rung', async ({ page }) => {
  test.setTimeout(90000);
  const { email } = await seedFeesTenant(0, 'reminder-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/reminders');
  await page.getByTestId('seed-ladder').click();
  await expect(page.getByTestId('reminder-rule')).toHaveCount(3);
  await expect(page.getByTestId('reminder-rule').first()).toContainText('Day 1 · sms · sms_d1');

  await page.getByTestId('rule-toggle').first().click();
  await expect(page.getByTestId('reminder-rule').first()).toContainText('paused');
});
