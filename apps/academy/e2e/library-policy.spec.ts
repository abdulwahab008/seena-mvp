import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O03: the Principal sets role and class-band borrowing policies; a teacher cannot change them.

test('the Principal configures borrowing policies; a teacher cannot', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { mk } = await seedLibraryTenant('libpolicy-e2e');
  const principal = await mk('principal', 'principal');
  const teacher = await mk('teacher', 'subject_teacher');

  await signInAs(page, principal.email);
  await page.goto('/library/policies');
  await page.getByLabel('Borrower role').selectOption('student');
  await page.getByLabel('Concurrent loans').fill('2');
  await page.getByLabel('Loan period (days)').fill('14');
  await page.getByLabel('Renewals').fill('1');
  await page.getByLabel('Fine per day (PKR)').fill('5');
  await page.getByLabel('Fine cap per loan (PKR)').fill('500');
  await page.getByTestId('save-policy').click();
  await expect(page.getByTestId('policy-row')).toHaveCount(1);
  await expect(page.getByTestId('policy-row')).toContainText('PKR 5');

  // a Nursery to Class 4 band with a shorter period
  await page.getByLabel('Class band from').selectOption({ label: 'Nursery' });
  await page.getByLabel('Class band to').selectOption({ label: 'Class 4' });
  await page.getByLabel('Concurrent loans').fill('1');
  await page.getByLabel('Loan period (days)').fill('7');
  await page.getByTestId('save-policy').click();
  await expect(page.getByTestId('policy-row')).toHaveCount(2);
  await expect(page.getByTestId('policy-table')).toContainText('Nursery to Class 4');

  const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const tp = await ctx.newPage();
  await signInAs(tp, teacher.email);
  await tp.goto('/library/policies');
  await expect(tp.getByTestId('policy-row')).toHaveCount(2);
  await expect(tp.getByTestId('save-policy')).toHaveCount(0);
  await ctx.close();
});
