import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a teacher publishes a quiz and a student takes it and is marked', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const seed = await seedFeesTenant(1, 'quiz');
  const { data: enrolment } = await seed.db.from('enrolment').select('student_id').eq('campus_id', seed.campusId).single();
  const studentEmail = `student.${enrolment!.student_id}@student.seena.local`;
  const { data: su } = await seed.db.auth.admin.createUser({ email: studentEmail, password: SEED_PASSWORD, email_confirm: true });
  await seed.db.from('student_portal_account').insert({ tenant_id: seed.tenant, campus_id: seed.campusId, student_id: enrolment!.student_id, user_id: su.user!.id, must_change_password: false });

  await signInAs(page, seed.email);
  await page.goto('/quizzes');
  await page.getByLabel('Class and section').selectOption({ index: 1 });
  await page.getByLabel('Title').fill('Fractions check');
  await page.getByRole('button', { name: 'Create and add questions' }).click();
  await expect(page.getByRole('heading', { name: 'Fractions check' })).toBeVisible();

  await page.getByLabel('Question').fill('1/2 + 1/4 = ?');
  await page.getByLabel('Options, one per line (2 to 6)').fill('1/4\n3/4\n2/6');
  await page.getByLabel('Right option number').fill('2');
  await page.getByLabel('Marks').fill('2');
  await page.getByRole('button', { name: 'Add question' }).click();
  await expect(page.getByTestId('quiz-question')).toHaveCount(1);
  await page.getByRole('button', { name: 'Publish quiz' }).click();
  await expect(page.getByTestId('quiz-status')).toBeVisible();

  const sctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const sp = await sctx.newPage();
  await sp.goto('/login');
  await sp.waitForLoadState('networkidle');
  await sp.getByLabel('Email').fill(studentEmail);
  await sp.getByLabel('Password').fill(SEED_PASSWORD);
  await sp.getByRole('button', { name: 'Sign in' }).click();
  await sp.waitForURL(/\/student/);
  await sp.goto('/student/quizzes');
  await sp.getByRole('link', { name: 'Start' }).click();
  await sp.getByLabel('3/4').check();
  await sp.getByRole('button', { name: 'Submit answers' }).click();
  await expect(sp.getByTestId('quiz-score')).toHaveText('You scored 2 out of 2.');
  await sctx.close();

  await page.reload();
  await expect(page.getByTestId('quiz-result')).toContainText('2 / 2');
});
