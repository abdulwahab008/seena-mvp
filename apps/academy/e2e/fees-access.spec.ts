import { test, expect, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// Fee data is for the people who handle fees: super admin, owner, principal and accountant. A class
// teacher used to be able to open /fees, see every family's challans and ledger, download any challan
// PDF and read a child's balance on the student profile. The admissions officer keeps the two fees pages
// their admissions work uses (concessions and sibling discounts).

async function signIn(page: Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/dashboard/);
}

test('only the fee staff see the fees area; the admissions officer keeps two pages', async ({ page }) => {
  test.setTimeout(240000);
  const { db, tenant, campusId, challans } = await seedFeesTenant(1, 'fees-access-e2e');
  const challan = challans[0]!;
  const runId = randomUUID().slice(0, 8);

  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challan.enrolment_id).single();
  const studentId = enrolment!.student_id as string;

  async function staffUser(role: string) {
    const email = `${role}-${runId}@fees-access-e2e.test`;
    const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
    await db.from('app_user').insert({ user_id: user.user!.id, tenant_id: tenant, app_role: role, full_name: `Fees Access ${role}` });
    await db.from('user_campus').insert({ user_id: user.user!.id, tenant_id: tenant, campus_id: campusId });
    return email;
  }
  const teacherEmail = await staffUser('subject_teacher');
  const accountantEmail = await staffUser('accountant');
  const admissionsEmail = await staffUser('admissions_officer');

  const feesNav = (p: Page) => p.getByRole('navigation', { name: 'Main' }).getByRole('button', { name: 'Fees', exact: true });

  // 1. A teacher has no Fees section, no fee figures, and is sent home from every fees URL.
  await signIn(page, teacherEmail);
  await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
  await expect(feesNav(page)).toHaveCount(0);
  await expect(page.getByRole('heading', { name: 'Outstanding fees' })).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Collect fees' })).toHaveCount(0);
  for (const path of ['/fees/challans', '/fees/counter', '/fees/concessions', '/fees/reports']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/dashboard$/);
  }
  // the student profile shows the student but none of their money
  await page.goto(`/students/${studentId}`);
  await expect(page.getByRole('heading', { name: 'Guardians' })).toBeVisible();
  for (const heading of ['Fees', 'Payments', 'Ledger', 'Concession awards']) {
    await expect(page.getByRole('heading', { name: heading, exact: true })).toHaveCount(0);
  }
  // and the challan PDF is not theirs to download
  const pdf = await page.request.get(`/api/challans/${challan.id}/pdf`);
  expect(pdf.status()).toBe(404);
  await page.context().clearCookies();

  // 2. An accountant keeps all of it.
  await signIn(page, accountantEmail);
  await expect(feesNav(page)).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Outstanding fees' })).toBeVisible();
  await page.goto('/fees/challans');
  await expect(page).toHaveURL(/\/fees\/challans$/);
  await page.goto(`/students/${studentId}`);
  await expect(page.getByRole('heading', { name: 'Ledger', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Payments', exact: true })).toBeVisible();
  const accountantPdf = await page.request.get(`/api/challans/${challan.id}/pdf`);
  expect(accountantPdf.status()).not.toBe(404);
  await page.context().clearCookies();

  // 3. An admissions officer gets concessions and sibling discounts, and nothing else under /fees.
  await signIn(page, admissionsEmail);
  await expect(feesNav(page)).toBeVisible();
  for (const path of ['/fees/concessions', '/fees/sibling-discounts']) {
    await page.goto(path);
    await expect(page).toHaveURL(new RegExp(`${path}$`));
  }
  for (const path of ['/fees/challans', '/fees/counter']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/dashboard$/);
  }
  await page.goto(`/students/${studentId}`);
  await expect(page.getByRole('heading', { name: 'Concession awards', exact: true })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Ledger', exact: true })).toHaveCount(0);
});
