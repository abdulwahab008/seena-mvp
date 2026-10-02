import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';
import { deriveSigningSecret, signBody } from '../lib/biometric/signature';

// FR-D08: HR registers a device and maps a code; the agent's signed batch becomes attendance (retries add nothing),
// an unsigned call is refused, an unknown code waits in the unmatched queue, and a missing sign-out is an exception.

// A device serial is unique across the whole database (the webhook identifies the device by it alone), so a fixed
// serial would make this spec fail on any database that already holds a previous run.
const SERIAL = `ZK-E2E-${Date.now().toString(36).toUpperCase()}${Math.random().toString(36).slice(2, 6).toUpperCase()}`;

test('a signed batch becomes attendance, a retry changes nothing, and exceptions surface', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, tenantId, mkUser, owner } = await seedHrTenant('bio-e2e');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  await signInAs(page, owner.email);
  await page.goto('/staff/biometric');

  await page.getByLabel('Device serial').fill(SERIAL);
  await page.getByTestId('register-device').click();
  const key = (await page.getByTestId('device-key').textContent())!.trim();
  expect(key).toMatch(/^[0-9a-f]{48}$/);

  await page.getByTestId('map-code-form').first().getByLabel('Code on device').fill('101');
  await page.getByTestId('map-code-form').first().getByLabel('Staff member').selectOption(teacher.staffId!);
  await page.getByTestId('map-code').first().click();
  await expect.poll(async () => (await db.from('staff_device_map').select('staff_id').eq('tenant_id', tenantId)).data?.length).toBe(1);

  const body = JSON.stringify({
    punches: [
      { code: '101', time: '2026-08-03T07:55:00+05:00', direction: 'in' },
      { code: '777', time: '2026-08-03T08:00:00+05:00', direction: 'in' },
    ],
  });
  const secret = deriveSigningSecret(key);

  const unsigned = await request.post('/api/webhooks/biometric', { data: body, headers: { 'content-type': 'application/json', 'x-device-serial': SERIAL, 'x-signature': 'sha256=' + '0'.repeat(64) } });
  expect(unsigned.status()).toBe(401);

  const headers = { 'content-type': 'application/json', 'x-device-serial': SERIAL, 'x-signature': signBody(secret, body) };
  const first = await request.post('/api/webhooks/biometric', { data: body, headers });
  expect(first.status()).toBe(200);
  expect((await first.json()).result).toMatchObject({ inserted: 1, unmatched: 1 });
  const retry = await request.post('/api/webhooks/biometric', { data: body, headers });
  expect((await retry.json()).result).toMatchObject({ inserted: 0, duplicates: 2 });

  const { data: rows } = await db.from('staff_attendance').select('status, anomaly, source').eq('staff_id', teacher.staffId!).eq('att_date', '2026-08-03');
  expect(rows).toEqual([{ status: 'present', anomaly: 'missing_out_punch', source: 'biometric' }]);

  // The exceptions list only shows the last 14 days, so move the day into range for the UI check.
  await db.from('staff_attendance').update({ att_date: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }) }).eq('staff_id', teacher.staffId!);
  await page.goto('/staff/biometric');
  await expect(page.getByTestId('exception-row')).toContainText('No sign-out punch');
  await expect(page.getByTestId('unmatched-row')).toContainText('777');
});
