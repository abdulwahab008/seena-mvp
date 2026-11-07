import { test, expect } from '@playwright/test';
import { seedFreshOwner } from './fixtures/fresh-owner';

test('an owner connects an SMS gateway and the API key is never shown back', async ({ page }) => {
  const owner = await seedFreshOwner('smsgw');
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel('Password').fill(owner.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/communication/sms-gateway');
  await page.getByLabel('Send URL').fill('https://api.example-sms.pk/send');
  await page.getByLabel('Sender mask').fill('SEENA');
  await page.getByLabel('API key', { exact: true }).fill('super-secret-key');
  await page.getByRole('button', { name: 'Save gateway' }).click();
  await expect(page.getByText('connected')).toBeVisible();

  await page.reload();
  await expect(page.getByText('connected')).toBeVisible();
  await expect(page.getByLabel('API key', { exact: true })).toHaveValue('');
  expect(await page.content()).not.toContain('super-secret-key');
});
