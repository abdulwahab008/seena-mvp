import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H07: the teacher lists who has not submitted an overdue assignment and notifies parents once a day.

test('overdue non-submitters are listed and notified once per day', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(3, 'hwnon-e2e');
  const enrolments = challans.map((c) => c.enrolment_id);
  const { data: enrol } = await db.from('enrolment').select('student_id, section_id, session_id').eq('id', enrolments[0]!).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'SCI', name_en: 'Science', name_ur: 'سائنس' }).select('id').single();
  const { data: auth } = await owner$.auth.getUser();
  const day = (n: number) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  const { data: hw } = await db
    .from('homework')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: enrol!.session_id, section_id: enrol!.section_id, subject_id: subject!.id, teacher_id: auth.user!.id, title: 'Overdue work', assigned_date: day(-5), due_date: day(-2), status: 'published', published_at: new Date().toISOString() })
    .select('id')
    .single();
  await db.from('homework_submission').insert({ tenant_id: tenant, campus_id: campusId, session_id: enrol!.session_id, homework_id: hw!.id, enrolment_id: enrolments[0]!, submission_text: 'done', status: 'submitted', submitted_at: new Date().toISOString() });
  for (const [i, e] of enrolments.slice(1).entries()) {
    const { data: en } = await db.from('enrolment').select('student_id').eq('id', e).single();
    const { data: g } = await db.from('guardian').insert({ tenant_id: tenant, name_en: `Parent ${i}`, phone_e164: `+92300555000${i}` }).select('id').single();
    await db.from('student_guardian').insert({ tenant_id: tenant, student_id: en!.student_id, guardian_id: g!.id, relationship: 'father', is_primary: true, receives_billing: true });
  }

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.goto('/homework');

  await page.getByTestId('show-non-submitters').click();
  await expect(page.getByTestId('non-submitter-count')).toHaveText('2 not submitted');
  await expect(page.getByTestId('non-submitter')).toHaveCount(2);
  await expect(page.getByTestId('non-submitter').first()).toContainText('+92300555');

  await page.getByTestId('notify-non-submitters').click();
  await expect(page.getByText('2 queued, 0 already notified today')).toBeVisible();
  await expect(page.getByTestId('non-submitter').first()).toContainText('Notified today');
  await expect(page.getByTestId('notify-non-submitters')).toBeDisabled();

  const { count } = await db.from('message').select('id', { count: 'exact', head: true }).like('idempotency_key', `hw_missing:${hw!.id}:%`);
  expect(count).toBe(2);
});
