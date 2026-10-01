import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q01: a block of 20 rooms x 4 beds becomes 80 beds; a room can be taken out of service without losing its beds.

test('the Principal builds a hostel block and takes a room out of service', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(0, 'hostel-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/hostel');
  const form = page.getByTestId('block-form');
  await form.getByLabel(/Block code/).fill('IQ');
  await form.getByLabel(/Block name/).fill('Iqbal Block');
  await form.getByLabel(/Block is for/).selectOption('male');
  await form.getByLabel(/^Rooms \*/).fill('20');
  await form.getByLabel(/Beds per room/).fill('4');
  await page.getByTestId('block-form-submit').click();
  await expect(page.getByTestId('block-row')).toHaveCount(1);
  await expect(page.getByTestId('beds-total')).toHaveText('80');

  const { count } = await db.from('hostel_bed').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant);
  expect(count).toBe(80);
  const { data: bed } = await db.from('hostel_bed').select('bed_code').eq('tenant_id', tenant).eq('bed_code', 'IQ-105-B3');
  expect(bed).toHaveLength(1);

  await page.getByTestId('block-row').getByRole('link').click();
  const room = page.getByTestId('room-form-105');
  await room.getByLabel(/Status/).selectOption('out_of_service');
  await page.getByTestId('room-form-105-submit').click();
  await expect(page.getByText('out of service').first()).toBeVisible();

  await page.goto('/hostel');
  await expect(page.getByTestId('block-row')).toContainText('4');
  const { count: still } = await db.from('hostel_bed').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant);
  expect(still).toBe(80);
});
