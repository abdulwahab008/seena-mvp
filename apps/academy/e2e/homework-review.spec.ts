import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H06: the teacher scores and checks a submission; the student's open page updates by itself.

test('a teacher checks a submission with a score and the parent sees it live', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(1, 'hwrev-e2e');
  const enrolmentId = challans[0]!.enrolment_id;
  const { data: enrol } = await db.from('enrolment').select('student_id, section_id, session_id').eq('id', enrolmentId).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'SCI', name_en: 'Science', name_ur: 'سائنس' }).select('id').single();
  const { data: auth } = await owner$.auth.getUser();
  const day = (n: number) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  const { data: hw } = await db
    .from('homework')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: enrol!.session_id, section_id: enrol!.section_id, subject_id: subject!.id, teacher_id: auth.user!.id, title: 'Review E2E', assigned_date: day(-1), due_date: day(3), status: 'published', published_at: new Date().toISOString() })
    .select('id')
    .single();
  await db.from('homework_submission').insert({ tenant_id: tenant, campus_id: campusId, session_id: enrol!.session_id, homework_id: hw!.id, enrolment_id: enrolmentId, submission_text: 'My answer', status: 'submitted', submitted_at: new Date().toISOString() });

  const parentEmail = `parent-${randomUUID().slice(0, 8)}@hwrev-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Review Parent', phone_e164: '+923001236666', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrol!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(parentEmail);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);
  await page.goto(`/portal/homework/submit?homework=${hw!.id}&enrolment=${enrolmentId}`);
  await expect(page.getByTestId('submission-realtime-status')).toHaveAttribute('data-status', 'SUBSCRIBED', { timeout: 20000 });
  await expect(page.getByTestId('teacher-feedback')).toHaveCount(0);

  const teacher = await browser.newContext({ baseURL: baseURL ?? undefined });
  const tp = await teacher.newPage();
  await tp.goto('/login');
  await tp.waitForLoadState('networkidle');
  await tp.getByLabel('Email').fill(email);
  await tp.getByLabel('Password').fill(SEED_PASSWORD);
  await tp.getByRole('button', { name: 'Sign in' }).click();
  await expect(tp).toHaveURL(/\/dashboard$/);
  await tp.goto('/homework');
  await tp.getByLabel('Max score').fill('10');
  await tp.getByRole('button', { name: 'Set', exact: true }).click();
  await expect(tp.getByLabel('Score out of 10')).toBeVisible();

  await tp.getByLabel('Feedback', { exact: true }).selectOption('good');
  await tp.getByLabel('Score out of 10').fill('11');
  await tp.getByTestId('check-submission').click();
  await expect(tp.getByTestId('review-error')).toHaveText('Score cannot exceed the maximum of 10');

  await tp.getByLabel('Score out of 10').fill('8');
  await tp.getByLabel('Remark', { exact: true }).fill('Neat and complete');
  await tp.getByTestId('check-submission').click();

  await expect(page.getByTestId('teacher-feedback')).toContainText('Neat and complete', { timeout: 5000 });
  await expect(page.getByTestId('teacher-feedback')).toContainText('8 / 10');
  await expect(page.getByTestId('teacher-feedback')).toContainText('good');
  await teacher.close();
});
