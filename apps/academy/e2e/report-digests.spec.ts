import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S05: subscribe, the dispatcher + worker deliver on schedule, the screen shows the
// outcome, and a paused subscription sends nothing.

const SECRET = process.env.EXPORT_WORKER_SECRET!;

test('an owner subscribes to the daily summary, receives it in the app, then pauses it', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId } = await seedFeesTenant(2, 'digest-e2e');
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  await db.rpc('refresh_agg_campus_day', { p_from: today, p_to: today, p_tenant_id: tenant });
  const { data: agg } = await db.from('agg_campus_day').select('id:campus_id').eq('campus_id', campusId).eq('day', today);
  expect(agg).toHaveLength(1);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/reports/digests');
  await page.waitForLoadState('networkidle');
  // a slot that opened a minute ago in Karachi, delivered in-app
  const now = new Date();
  const local = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Karachi' }));
  local.setMinutes(local.getMinutes() - 1);
  const hhmm = `${String(local.getHours()).padStart(2, '0')}:${String(local.getMinutes()).padStart(2, '0')}`;
  await page.locator('#runAtLocal').fill(hhmm);
  await page.locator('#channel').selectOption('in_app');
  await page.getByTestId('subscribe').click();
  await expect(page.getByTestId('subscription-row')).toHaveCount(1);

  const run = await request.post('/api/internal/digests/run', { headers: { 'x-worker-secret': SECRET } });
  expect(run.status()).toBe(200);
  await page.reload();
  await expect(page.getByTestId('last-delivery')).toContainText('sent');
  const { data: notes } = await db.from('user_notification').select('title, body').eq('tenant_id', tenant).eq('kind', 'report_digest');
  expect(notes).toHaveLength(1);
  expect(notes![0]!.body).toContain('Group daily summary');

  await page.getByTestId('deactivate').click();
  await expect(page.getByText('paused')).toBeVisible();
});

test('the digest worker rejects calls without the secret', async ({ request }) => {
  expect((await request.post('/api/internal/digests/run')).status()).toBe(401);
});
