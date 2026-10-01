import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-T13: generate a return as of a census date, see the roll reconcile, download the file, and
// see that a student who left after the census date is still counted.

test('the owner generates a census return counted as of the census date', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(3, 'census-e2e');

  // Two students joined long ago; one of them left AFTER the census date; one joined AFTER it.
  const { data: enrolments } = await db.from('enrolment').select('id').eq('tenant_id', tenant).order('created_at');
  await db.from('enrolment').update({ joined_on: '2025-04-01' }).eq('id', enrolments![0]!.id);
  await db.from('enrolment').update({ joined_on: '2025-04-01', left_on: '2026-04-10', status: 'transferred' }).eq('id', enrolments![1]!.id);
  await db.from('enrolment').update({ joined_on: '2026-03-15' }).eq('id', enrolments![2]!.id);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/compliance/census');
  await page.waitForLoadState('networkidle');
  await page.locator('#framework').selectOption('kpk_emis');
  await page.locator('#censusDate').fill('2026-03-01');
  await page.getByTestId('generate-census').click();
  await expect(page.getByTestId('census-run')).toHaveCount(1);
  await expect(page.getByTestId('census-run')).toContainText('2 students on the roll');
  await expect(page.getByTestId('census-run')).toContainText('reconciliation passed');

  const link = await page.getByTestId('census-download').first().getAttribute('href');
  const file = await page.request.get(link!);
  expect(file.status()).toBe(200);
  const text = (await file.body()).toString('utf8');
  expect(text).toContain('Census date,2026-03-01');
  expect(text).toContain('Total');

  // Regenerating gives the same file.
  const firstSha = (await db.from('census_return_run').select('file_sha256').eq('tenant_id', tenant).single()).data!.file_sha256;
  await page.getByTestId('generate-census').click();
  await expect(page.getByTestId('census-run')).toHaveCount(2);
  const shas = (await db.from('census_return_run').select('file_sha256').eq('tenant_id', tenant)).data!.map((r) => r.file_sha256);
  expect(new Set(shas)).toEqual(new Set([firstSha]));
});
