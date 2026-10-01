import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P06: the ingest hook answers 404 while transport_gps is off, accepts pings once it is on, and the office sees the position.

test('GPS pings are refused while the flag is off and land once it is on', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'gps-e2e');
  const bus = await owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'TRK-1', p_seat_capacity: 30 });
  expect(bus.error).toBeNull();
  const key = await owner$.rpc('create_gps_credential', { p_label: 'e2e vendor' });
  expect(key.error).toBeNull();

  const ping = { pings: [{ reg_no: 'TRK-1', lat: 31.5, lng: 74.3, speed: 42, ts: new Date().toISOString() }] };
  const headers = { 'x-device-key': key.data as string };

  const off = await request.post('/api/webhooks/transport/gps', { headers, data: ping });
  expect(off.status()).toBe(404);
  const none = await owner$.from('transport_vehicle_position_latest').select('vehicle_id');
  expect(none.data).toHaveLength(0);

  expect((await request.post('/api/webhooks/transport/gps', { data: ping })).status()).toBe(401);

  await db.from('tenant_feature_override').insert({ tenant_id: tenant, feature_code: 'transport_gps', enabled: true });
  const on = await request.post('/api/webhooks/transport/gps', { headers, data: ping });
  expect(on.status()).toBe(200);
  expect(await on.json()).toMatchObject({ accepted: 1 });
  const again = await request.post('/api/webhooks/transport/gps', { headers, data: ping });
  expect(await again.json()).toMatchObject({ accepted: 0, duplicates: 1 });

  const big = { pings: Array.from({ length: 101 }, (_, i) => ({ reg_no: 'TRK-1', lat: 31.5, lng: 74.3, ts: Date.now() - i * 1000 })) };
  expect((await request.post('/api/webhooks/transport/gps', { headers, data: big })).status()).toBe(413);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto('/transport/live');
  await expect(page.getByTestId('gps-flag')).toContainText('on');
  await expect(page.getByTestId('position-row')).toHaveCount(1);
  await expect(page.getByTestId('position-row')).toContainText('TRK-1');
});
