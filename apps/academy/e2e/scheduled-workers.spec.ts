import { test, expect } from '@playwright/test';

// vercel.json schedules these with a GET carrying the cron secret; anything else is refused.
const PATHS = ['/api/internal/admissions/reminders', '/api/internal/messages', '/api/internal/digests/run', '/api/internal/exports/purge', '/api/internal/storage/purge', '/api/internal/retention/run'];

test('every scheduled worker runs for the cron secret and refuses anyone else', async ({ request }) => {
  test.setTimeout(120000);
  const auth = { authorization: `Bearer ${process.env.CRON_SECRET}` };
  for (const path of PATHS) {
    expect((await request.get(path)).status(), `${path} without a secret`).toBe(401);
    expect((await request.get(path, { headers: { authorization: 'Bearer wrong-secret-0123456789' } })).status(), `${path} with a wrong secret`).toBe(401);
    expect((await request.get(path, { headers: auth })).status(), `${path} with the cron secret`).toBe(200);
  }
});
