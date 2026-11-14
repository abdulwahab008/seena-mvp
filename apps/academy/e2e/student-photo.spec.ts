import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';
import { makeSolidPng } from './fixtures/png';

test('an owner uploads, replaces and removes a student photo, and ID cards print with it', async ({ page, context }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'photo-e2e');
  const { data: student } = await seed.db.from('student').select('id').eq('tenant_id', seed.tenant).single();
  await signInAs(page, seed.email);

  await page.goto(`/students/${student!.id}`);
  await page.getByLabel(/^Photo of /).setInputFiles({ name: 'kid.png', mimeType: 'image/png', buffer: makeSolidPng(300, 400) });
  await expect(page.getByText('Photo saved.')).toBeVisible();
  await expect(page.getByTestId('profile-photo')).toBeVisible();
  const first = (await seed.db.from('student').select('photo_path').eq('id', student!.id).single()).data!.photo_path!;
  expect(first).toMatch(new RegExp(`^${seed.tenant}/${seed.campusId}/${student!.id}-`));

  await page.getByLabel(/^Photo of /).setInputFiles({ name: 'kid2.png', mimeType: 'image/png', buffer: makeSolidPng(320, 400) });
  await expect(page.getByText('Photo saved.')).toHaveCount(1);
  await expect.poll(async () => (await seed.db.from('student').select('photo_path').eq('id', student!.id).single()).data!.photo_path).not.toBe(first);

  await page.goto('/id-cards');
  const opened = context.waitForEvent('request', (r) => r.url().includes('/api/id-cards?'));
  await page.getByRole('button', { name: 'Print cards' }).click();
  const response = await page.request.get((await opened).url());
  expect(response.status()).toBe(200);
  expect((await response.body()).subarray(0, 4).toString()).toBe('%PDF');

  await page.goto(`/students/${student!.id}`);
  await page.getByRole('button', { name: 'Remove photo' }).click();
  await expect(page.getByText('Photo removed.')).toBeVisible();
  await expect(page.getByTestId('profile-photo')).toHaveCount(0);
  await expect.poll(async () => (await seed.db.from('student').select('photo_path').eq('id', student!.id).single()).data!.photo_path).toBeNull();
});
