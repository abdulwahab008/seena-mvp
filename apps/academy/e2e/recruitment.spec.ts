import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('HR posts an opening and moves an applicant from application to hire', async ({ page }) => {
  const seed = await seedFeesTenant(0, 'recruit');
  await signInAs(page, seed.email);

  await page.goto('/staff/recruitment');
  await page.getByLabel('Job title').fill('Maths Teacher');
  await page.getByRole('button', { name: 'Post opening' }).click();
  await expect(page.getByRole('link', { name: /Maths Teacher/ })).toBeVisible();

  await page.getByLabel('Candidate name').fill('Ayesha Khan');
  await page.getByLabel('Qualification').fill('MSc Mathematics');
  await page.getByRole('button', { name: 'Add applicant' }).click();
  const row = page.getByTestId('applicant-row').filter({ hasText: 'Ayesha Khan' });
  await expect(row.getByTestId('applicant-stage')).toHaveText('Applied');

  await row.getByRole('button', { name: 'Shortlist' }).click();
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('applicant-stage')).toHaveText('Shortlisted');

  await row.getByRole('button', { name: 'Schedule interview' }).click();
  await page.getByLabel('Interview time').fill('2026-12-01T10:00');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('applicant-stage')).toHaveText('Interview');

  await row.getByRole('button', { name: 'Make offer' }).click();
  await page.getByRole('button', { name: 'Save' }).click();
  await row.getByRole('button', { name: 'Mark hired' }).click();
  await page.getByLabel('Note (optional)').fill('Joins on 1 Jan');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('applicant-stage')).toHaveText('Hired');
  await expect(row).toContainText('Joins on 1 Jan');
});
