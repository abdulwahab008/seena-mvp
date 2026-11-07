import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

test('an owner adds a donor, records a donation, sponsors a student and pays the sponsored fee', async ({ page }) => {
  const { db, email, challans } = await seedFeesTenant(1, 'donors');
  const { data: enrol } = await db.from('enrolment').select('student(gr_number)').eq('id', challans[0]!.enrolment_id).single();
  const gr = (Array.isArray(enrol!.student) ? enrol!.student[0] : enrol!.student) as { gr_number: string };

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/fees/donors');
  await page.getByLabel('Name').fill('Haji Rashid');
  await page.getByRole('button', { name: 'Add donor' }).click();
  await expect(page.getByText('Donor added.')).toBeVisible();

  await page.getByLabel('Donor', { exact: true }).selectOption({ label: 'Haji Rashid' });
  await page.getByLabel('Amount (PKR)', { exact: true }).fill('10000');
  await page.getByLabel('Purpose').selectOption('zakat');
  await page.getByRole('button', { name: 'Record donation' }).click();
  await expect(page.getByTestId('donation-row')).toContainText('PKR 10,000.00');

  await page.getByLabel('Sponsor', { exact: true }).selectOption({ label: 'Haji Rashid' });
  await page.getByLabel('Student GR number').fill(gr.gr_number);
  await page.getByLabel('Monthly amount (PKR)').fill('5000');
  await page.getByRole('button', { name: 'Save sponsorship' }).click();
  await expect(page.getByTestId('sponsorship-row')).toContainText('PKR 5,000.00');

  await page.getByRole('button', { name: 'Pay sponsored fees' }).click();
  await expect(page.getByText("Paid 1 student's fees", { exact: false })).toBeVisible();
  await page.reload();
  await expect(page.getByTestId('sponsorship-row').getByRole('cell').nth(3)).toHaveText('PKR 5,000.00');
  await page.getByRole('button', { name: 'Pay sponsored fees' }).click();
  await expect(page.getByText('Nothing to pay for that month.')).toBeVisible();
});
