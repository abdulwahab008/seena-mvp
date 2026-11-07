import { test, expect } from '@playwright/test';

test('the message worker refuses calls without the worker or cron secret', async ({ request }) => {
  expect((await request.get('/api/internal/messages')).status()).toBe(401);
  expect((await request.get('/api/internal/messages', { headers: { authorization: 'Bearer not-the-secret' } })).status()).toBe(401);
  expect((await request.post('/api/internal/messages', { headers: { 'x-worker-secret': 'not-the-secret' } })).status()).toBe(401);
});
