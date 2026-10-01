import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P04: allocating a student to a stop posts the transport fee; a full route refuses and offers the waiting list.

test('allocation posts the slab fee, a full route is refused and the student joins the waiting list', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(2, 'alloc-e2e');

  const rpc = async <T,>(p: PromiseLike<{ data: T; error: { message: string } | null }>) => {
    const r = await p;
    expect(r.error).toBeNull();
    return r.data;
  };
  const route = await rpc(owner$.rpc('save_transport_route', { p_campus_id: campusId, p_code: 'R-04', p_name: 'Johar Town', p_shift: 'morning' }));
  const slab = await rpc(owner$.rpc('save_fare_slab', { p_campus_id: campusId, p_code: 'ZONE-B', p_name: 'Zone B', p_monthly_amount_paisa: 350000, p_effective_from: '2026-01-01' }));
  await rpc(owner$.rpc('add_transport_stop', { p_route_id: route as string, p_name: 'Gate One', p_pickup_time: '06:45', p_drop_time: '14:10', p_fare_slab_id: slab as string }));
  const bus = await rpc(owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'MINI-1', p_seat_capacity: 1 }));
  for (const t of ['fitness', 'insurance', 'token_tax']) {
    await rpc(owner$.rpc('add_vehicle_document', { p_vehicle_id: bus as string, p_doc_type: t, p_expires_on: '2031-01-01' }));
  }
  const driver = await rpc(owner$.rpc('save_transport_crew', { p_campus_id: campusId, p_full_name: 'Aslam', p_cnic: '35202-1234567-1', p_crew_role: 'driver', p_licence_no: 'L1', p_licence_class: 'HTV', p_licence_expires_on: '2031-01-01', p_police_verified_on: '2026-01-01' }));
  await rpc(owner$.rpc('assign_transport_trip', { p_route_id: route as string, p_vehicle_id: bus as string, p_driver_id: driver as string, p_from: '2026-01-01' }));

  const { data: students } = await db.from('student').select('gr_number').eq('tenant_id', tenant).order('gr_number');
  expect(students).toHaveLength(2);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transport/allocations');
  const form = page.getByTestId('allocate-form');
  await form.getByLabel(/GR number/).fill(students![0]!.gr_number);
  await form.getByLabel(/Pickup stop/).selectOption({ index: 1 });
  await form.getByLabel(/Starts on/).fill('2026-08-11');
  await page.getByTestId('allocate-form-submit').click();
  await expect(page.getByTestId('allocation-row')).toHaveCount(1);

  const { data: lines } = await db.from('fee_ledger').select('amount_paisa, source_type').eq('tenant_id', tenant).eq('source_type', 'transport_allocation');
  expect(lines).toHaveLength(1);
  expect(lines![0]!.amount_paisa).toBe(350000); // full-month is the default policy

  // The one-seat vehicle is now full.
  await form.getByLabel(/GR number/).fill(students![1]!.gr_number);
  await form.getByLabel(/Pickup stop/).selectOption({ index: 1 });
  await form.getByLabel(/Starts on/).fill('2026-08-11');
  await page.getByTestId('allocate-form-submit').click();
  await expect(page.getByTestId('allocate-form-error')).toContainText('1/1');

  const wl = page.getByTestId('waitlist-form');
  await wl.getByLabel(/GR number/).fill(students![1]!.gr_number);
  await wl.getByLabel(/Route/).selectOption({ index: 1 });
  await page.getByTestId('waitlist-form-submit').click();
  await expect(page.getByTestId('waitlist').locator('li')).toHaveCount(1);
});
