import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the transport report shows riders, seat occupancy and monthly fares per route', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'route-report-e2e');
  const rpc = async <T,>(p: PromiseLike<{ data: T; error: { message: string } | null }>) => {
    const r = await p;
    expect(r.error).toBeNull();
    return r.data;
  };
  const route = await rpc(owner$.rpc('save_transport_route', { p_campus_id: campusId, p_code: 'R-07', p_name: 'Dhok Amb', p_shift: 'morning' }));
  const slab = await rpc(owner$.rpc('save_fare_slab', { p_campus_id: campusId, p_code: 'ZONE-A', p_name: 'Zone A', p_monthly_amount_paisa: 300000, p_effective_from: '2026-01-01' }));
  await rpc(owner$.rpc('add_transport_stop', { p_route_id: route as string, p_name: 'Main Chowk', p_pickup_time: '07:00', p_drop_time: '14:00', p_fare_slab_id: slab as string }));
  const bus = await rpc(owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'RIP-123', p_seat_capacity: 4 }));
  for (const t of ['fitness', 'insurance', 'token_tax']) {
    await rpc(owner$.rpc('add_vehicle_document', { p_vehicle_id: bus as string, p_doc_type: t, p_expires_on: '2031-01-01' }));
  }
  const driver = await rpc(owner$.rpc('save_transport_crew', { p_campus_id: campusId, p_full_name: 'Bashir', p_cnic: '35202-7654321-1', p_crew_role: 'driver', p_licence_no: 'L2', p_licence_class: 'HTV', p_licence_expires_on: '2031-01-01', p_police_verified_on: '2026-01-01' }));
  await rpc(owner$.rpc('assign_transport_trip', { p_route_id: route as string, p_vehicle_id: bus as string, p_driver_id: driver as string, p_from: '2026-01-01' }));
  const { data: stop } = await db.from('transport_stop').select('id').eq('route_id', route as string).single();
  const { data: student } = await db.from('student').select('id').eq('tenant_id', tenant).single();
  await rpc(owner$.rpc('allocate_transport', { p_student_id: student!.id, p_pickup_stop: stop!.id, p_drop_stop: stop!.id, p_from: '2026-08-01' }));

  await signInAs(page, email);
  await page.goto('/transport/report');
  const row = page.getByTestId('route-report-row');
  await expect(row.locator('td')).toHaveText(['R-07 Dhok Amb', 'morning', 'RIP-123', '4', '1', '25%', '3,000']);
});
