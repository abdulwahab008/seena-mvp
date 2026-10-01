import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P05: mark-all-boarded plus exceptions in one batch; an offline submit is queued and sent once on reconnect.

test('a pickup leg is marked offline, queued, and stored exactly once on reconnect', async ({ page, context }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(3, 'board-e2e');
  const ok = async <T,>(p: PromiseLike<{ data: T; error: { message: string } | null }>) => {
    const r = await p;
    expect(r.error).toBeNull();
    return r.data;
  };
  const route = await ok(owner$.rpc('save_transport_route', { p_campus_id: campusId, p_code: 'R-07', p_name: 'Cantt', p_shift: 'morning' }));
  const slab = await ok(owner$.rpc('save_fare_slab', { p_campus_id: campusId, p_code: 'A', p_name: 'Zone A', p_monthly_amount_paisa: 300000, p_effective_from: '2026-01-01' }));
  const stop = await ok(owner$.rpc('add_transport_stop', { p_route_id: route as string, p_name: 'Liberty', p_pickup_time: '06:50', p_fare_slab_id: slab as string }));
  const bus = await ok(owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'BUS-9', p_seat_capacity: 40 }));
  for (const t of ['fitness', 'insurance', 'token_tax']) await ok(owner$.rpc('add_vehicle_document', { p_vehicle_id: bus as string, p_doc_type: t, p_expires_on: '2031-01-01' }));
  const driver = await ok(owner$.rpc('save_transport_crew', { p_campus_id: campusId, p_full_name: 'Aslam', p_cnic: '35202-1234567-1', p_crew_role: 'driver', p_licence_no: 'L1', p_licence_class: 'HTV', p_licence_expires_on: '2031-01-01', p_police_verified_on: '2026-01-01' }));
  await ok(owner$.rpc('assign_transport_trip', { p_route_id: route as string, p_vehicle_id: bus as string, p_driver_id: driver as string, p_from: '2026-01-01' }));
  const { data: students } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).order('gr_number');
  for (const s of students!) await ok(owner$.rpc('allocate_transport', { p_student_id: s.id, p_pickup_stop: stop as string, p_drop_stop: stop as string, p_from: '2026-01-05' }));

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transport/boarding');
  await page.getByTestId('open-leg').click();
  await expect(page.getByTestId('boarding-sheet')).toBeVisible();
  await expect(page.getByTestId('manifest-row')).toHaveCount(3);

  // The phone loses signal before the batch is sent.
  await context.setOffline(true);
  await page.getByTestId('mark-all').click();
  await page.getByTestId(`student-${students![2]!.gr_number}`).click(); // exception: absent
  await page.getByTestId('submit-batch').click();
  await expect(page.getByTestId('boarding-status')).toContainText('Offline');

  await context.setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await expect(page.getByTestId('boarding-status')).toContainText('Saved on the server');

  const { data: events } = await db.from('transport_boarding_event').select('state').eq('tenant_id', tenant);
  expect(events).toHaveLength(3);
  expect(events!.filter((e) => e.state === 'absent')).toHaveLength(1);
});
