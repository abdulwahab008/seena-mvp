import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a teacher shares a PDF with the campus and it can be downloaded', async ({ page }) => {
  const seed = await seedFeesTenant(1, 'downloads');
  await signInAs(page, seed.email);

  await page.goto('/downloads');
  await expect(page.getByRole('heading', { name: 'Download centre' })).toBeVisible();
  await page.getByLabel('Title').fill('Term 1 syllabus');
  await page.getByLabel('Type').selectOption('syllabus');
  await page.getByLabel('File (up to 10 MB)').setInputFiles({ name: 'syllabus.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%%EOF\n') });
  await page.getByRole('button', { name: 'Share' }).click();

  const row = page.getByTestId('download-row').filter({ hasText: 'Term 1 syllabus' });
  await expect(row).toContainText('Whole campus');
  const href = await row.getByRole('link', { name: 'Term 1 syllabus' }).getAttribute('href');
  const response = await page.request.get(href!);
  expect(response.status()).toBe(200);
  expect((await response.body()).toString()).toContain('%PDF');

  await row.getByRole('button', { name: 'Remove' }).click();
  await expect(page.getByTestId('download-row')).toHaveCount(0);
});
