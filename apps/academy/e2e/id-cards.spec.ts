import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('an owner prints student ID cards for the campus as a PDF', async ({ page, context }) => {
  const seed = await seedFeesTenant(2, 'idcards');
  await signInAs(page, seed.email);

  await page.goto('/id-cards');
  await expect(page.getByRole('heading', { name: 'ID cards' })).toBeVisible();

  const opened = context.waitForEvent('request', (r) => r.url().includes('/api/id-cards?'));
  await page.getByRole('button', { name: 'Print cards' }).click();
  const url = (await opened).url();

  const response = await page.request.get(url);
  expect(response.status()).toBe(200);
  expect(response.headers()['content-type']).toBe('application/pdf');
  expect((await response.body()).subarray(0, 4).toString()).toBe('%PDF');
});

test('a teacher cannot print ID cards', async ({ page }) => {
  const seed = await seedFeesTenant(1, 'idcards-deny');
  await signInAs(page, seed.email);
  await seed.db.from('app_user').update({ app_role: 'subject_teacher' }).eq('tenant_id', seed.tenant);
  const response = await page.request.get(`/api/id-cards?kind=student&campusId=${seed.campusId}&validUntil=2027-03-31`);
  expect([401, 403]).toContain(response.status());
});
