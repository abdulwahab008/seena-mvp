import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a principal sets up a halqa and records a sabaq; progress shows the para reached', async ({ page }) => {
  const seed = await seedFeesTenant(1, 'hifz');
  const { data: kid } = await seed.db.from('student').select('name_en').eq('tenant_id', seed.tenant).single();
  await signInAs(page, seed.email);

  await page.goto('/hifz');
  await page.getByLabel('Name').fill('Halqa Abu Bakr');
  await page.getByRole('button', { name: 'Create halqa' }).click();
  await expect(page.getByRole('heading', { name: 'Halqa Abu Bakr: progress' })).toBeVisible();

  await page.getByLabel('Add a student to this halqa').selectOption({ index: 1 });
  expect(kid!.name_en).toBeTruthy();
  await page.getByRole('button', { name: 'Add', exact: true }).click();
  await expect(page.getByTestId('hifz-progress-row')).toHaveCount(1);

  await page.getByLabel('Student', { exact: true }).selectOption({ index: 1 });
  await page.getByLabel('Para from').fill('1');
  await page.getByLabel('Para to').fill('2');
  await page.getByLabel('Surah / ayat or pages').fill('Al-Baqarah 1-20');
  await page.getByLabel('Mistakes', { exact: true }).fill('2');
  await page.getByLabel('Grade').selectOption('good');
  await page.getByRole('button', { name: 'Save lesson' }).click();
  await expect(page.getByTestId('hifz-progress-row').locator('td').nth(1)).toHaveText('2');
});
