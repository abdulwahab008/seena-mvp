import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P02: a vehicle register that shows an expired fitness certificate and refuses the bus at the database.

test('the register flags an expired fitness certificate and the database refuses the assignment', async ({ page }) => {
  test.setTimeout(120000);
  const { email, owner$, campusId } = await seedFeesTenant(0, 'veh-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transport/fleet');
  const form = page.getByTestId('vehicle-form');
  await form.getByLabel(/Registration no/).fill('LEB-1234');
  await form.getByLabel(/Seats/).fill('42');
  await page.getByTestId('vehicle-form-submit').click();
  await expect(page.getByTestId('vehicle-row')).toHaveCount(1);

  const doc = page.getByTestId('document-form');
  await doc.getByLabel(/Vehicle/).selectOption({ label: 'LEB-1234' });
  await doc.getByLabel(/Document \*/).selectOption('fitness');
  await doc.getByLabel(/Expires on/).fill('2026-07-01');
  await page.getByTestId('document-form-submit').click();
  await expect(page.getByTestId('doc-fitness')).toContainText('expired');

  const { data: veh } = await owner$.from('transport_vehicle').select('id').eq('campus_id', campusId).single();
  const { error } = await owner$.rpc('assert_vehicle_roadworthy', { p_vehicle_id: veh!.id, p_on: '2026-07-29' });
  expect(error?.message).toContain('fitness certificate expired 28 days ago');
});
