import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

const karachiDay = (offset = 0) => new Date(Date.now() + offset * 86400000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

test('a principal lets a blocked van run for a set period, it is assigned, then the assignment is ended', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, campusId } = await seedFeesTenant(0, 'van-override-e2e');
  const today = karachiDay();

  const route = await owner$.rpc('save_transport_route', { p_campus_id: campusId, p_code: 'R-07', p_name: 'Canal Road', p_shift: 'morning' });
  const van = await owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'VAN-7', p_seat_capacity: 12 });
  const driver = await owner$.rpc('save_transport_crew', {
    p_campus_id: campusId, p_full_name: 'Rafiq', p_cnic: '35202-7654321-3', p_crew_role: 'driver',
    p_licence_no: 'LH-77', p_licence_class: 'LTV', p_licence_expires_on: karachiDay(800),
  });
  expect(route.error).toBeNull();
  expect(van.error).toBeNull();
  expect(driver.error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  // No fitness, insurance or token tax on file: the van is blocked.
  await page.goto('/transport/assignments');
  const assign = page.getByTestId('assign-form');
  await assign.getByLabel(/^Route/).selectOption({ index: 1 });
  await assign.getByLabel(/^Vehicle/).selectOption({ index: 1 });
  await assign.getByLabel(/^Driver/).selectOption({ index: 1 });
  await assign.getByLabel(/^From/).fill(today);
  await page.getByTestId('assign-form-submit').click();
  await expect(page.getByTestId('assign-form-error')).toContainText('Vehicle blocked');

  await page.goto('/transport/fleet');
  const override = page.getByTestId('vehicle-override-form');
  await override.getByLabel('Vehicle').selectOption({ index: 1 });
  await override.getByLabel('Last day').fill(karachiDay(30));
  await override.getByLabel('Reason').fill('short');
  await page.getByTestId('vehicle-override-form-submit').click();
  await expect(page.getByTestId('vehicle-override-form-error')).toContainText('at least 10 characters');
  await override.getByLabel('Reason').fill('Fitness renewal booked, papers due next week');
  await page.getByTestId('vehicle-override-form-submit').click();
  await expect(page.getByTestId('vehicle-overrides')).toContainText('VAN-7 may run');

  await page.goto('/transport/assignments');
  await assign.getByLabel(/^Route/).selectOption({ index: 1 });
  await assign.getByLabel(/^Vehicle/).selectOption({ index: 1 });
  await assign.getByLabel(/^Driver/).selectOption({ index: 1 });
  await assign.getByLabel(/^From/).fill(today);
  await page.getByTestId('assign-form-submit').click();
  await expect(page.getByTestId('assignment-row')).toHaveCount(1);

  const end = page.getByTestId('end-assignment-form');
  await end.getByLabel('Assignment').selectOption({ index: 1 });
  await end.getByLabel('Last day').fill(today);
  await page.getByTestId('end-assignment-form-submit').click();
  await expect(page.getByText('Assignment ended.')).toBeVisible();

  const { data: rows } = await db.from('transport_trip_assignment').select('effective_to').eq('campus_id', campusId);
  expect(rows?.[0]?.effective_to).toBe(today);
});
