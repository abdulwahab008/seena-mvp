import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test("an owner resets a class's student passwords and the student signs in with the slip", async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'bulk-reset');
  const { data: enrolment } = await seed.db.from('enrolment').select('student_id, student(gr_number)').eq('campus_id', seed.campusId).single();
  const gr = (Array.isArray(enrolment!.student) ? enrolment!.student[0] : enrolment!.student) as { gr_number: string };
  const studentEmail = `student.${enrolment!.student_id}@student.seena.local`;
  const { data: su } = await seed.db.auth.admin.createUser({ email: studentEmail, password: SEED_PASSWORD, email_confirm: true });
  await seed.db.from('student_portal_account').insert({ tenant_id: seed.tenant, campus_id: seed.campusId, student_id: enrolment!.student_id, user_id: su.user!.id, must_change_password: false });

  await signInAs(page, seed.email);
  await page.goto('/users');
  await page.getByLabel('Section').selectOption({ index: 1 });
  await page.getByRole('button', { name: 'Reset passwords' }).click();
  await page.getByRole('button', { name: 'Reset', exact: true }).click();
  const slip = page.getByTestId('reset-slip');
  await expect(slip).toHaveCount(1);
  await expect(slip).toContainText(gr.gr_number);
  const password = (await slip.locator('.font-mono').innerText()).trim();
  expect(password).toHaveLength(10);

  const sctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const sp = await sctx.newPage();
  await sp.goto('/login');
  await sp.waitForLoadState('networkidle');
  await sp.getByLabel('Email').fill(studentEmail);
  await sp.getByLabel('Password').fill(SEED_PASSWORD);
  await sp.getByRole('button', { name: 'Sign in' }).click();
  await expect(sp.getByText('That sign-in did not match', { exact: false })).toBeVisible();
  await sp.getByLabel('Password').fill(password);
  await sp.getByRole('button', { name: 'Sign in' }).click();
  await sp.waitForURL(/\/student/);
  await sctx.close();
});
