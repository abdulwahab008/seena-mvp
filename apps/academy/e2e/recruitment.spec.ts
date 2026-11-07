import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('HR posts an opening, scores the interview, makes an offer, hires, and sees them on the HR dashboard', async ({ page }) => {
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

  await row.getByRole('button', { name: 'Score interview' }).click();
  await page.getByLabel('Subject knowledge').selectOption('5');
  await page.getByLabel('Teaching demo').selectOption('4');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Scorecard saved.')).toBeVisible();
  await expect(row.getByTestId('applicant-score')).toContainText('1 recommend hiring');

  await row.getByRole('button', { name: 'Make offer' }).click();
  await page.getByLabel('Monthly salary (PKR)').fill('85000');
  await page.getByLabel('Joining date').fill('2027-01-01');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('applicant-stage')).toHaveText('Offered');
  await expect(row.getByTestId('applicant-offer')).toContainText('PKR 85,000.00 a month');

  await row.getByRole('button', { name: 'Mark hired' }).click();
  await page.getByLabel('Employee code').fill('T-101');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Enter the CNIC.')).toBeVisible();
  await page.getByLabel('CNIC (if not on the application)').fill('35202-7654321-2');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('applicant-stage')).toHaveText('Hired');

  await page.goto('/staff/hr-dashboard');
  await expect(page.getByTestId('hr-kpi-headcount')).toHaveText('1');
  await page.getByLabel('Employee code').fill('T-101');
  await page.getByLabel('CNIC expires on').fill(new Date(Date.now() + 20 * 86400000).toISOString().slice(0, 10));
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('hr-cnic-expiring')).toContainText('Ayesha Khan');
});
