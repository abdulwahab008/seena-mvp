import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H11: a teacher marks chapters covered; the weighted percentage updates and the history records the change.

test('a teacher records syllabus coverage and sees the period-weighted percentage', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(0, 'cover-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { error: syllabusError } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: subject!.id, p_board: 'FBISE',
    p_units: [
      { title: 'Motion', planned_periods: 12 },
      { title: 'Force', planned_periods: 24 },
      { title: 'Energy', planned_periods: 24 },
    ],
  });
  expect(syllabusError).toBeNull();

  const email = `teacher-${tenant.slice(0, 8)}@cover-e2e.test`;
  const { data: created } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: created.user!.id, tenant_id: tenant, app_role: 'subject_teacher', full_name: 'Physics Teacher' });
  await db.from('user_campus').insert({ user_id: created.user!.id, tenant_id: tenant, campus_id: campusId });
  await db.from('section_subject_teacher').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, subject_id: subject!.id, staff_id: created.user!.id, effective_from: '2000-01-01' });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/syllabus-coverage');
  await expect(page.getByTestId('coverage-pct')).toContainText('0.00% covered');

  // Completing the 12-period unit of 60 is 20%, not one third.
  const first = page.getByTestId('coverage-row').first();
  await first.getByLabel(/^Status of/).selectOption('completed');
  await first.getByLabel(/^Completed on/).fill('2026-10-12');
  await first.getByTestId('save-coverage').click();
  await expect(page.getByTestId('coverage-pct')).toContainText('20.00% covered');
  await expect(page.getByTestId('coverage-row').first()).toContainText('start date inferred');

  // A completion before the start is refused with the spec wording.
  const second = page.getByTestId('coverage-row').nth(1);
  await second.getByLabel(/^Status of/).selectOption('completed');
  await second.getByLabel(/^Started on/).fill('2026-10-10');
  await second.getByLabel(/^Completed on/).fill('2026-10-05');
  await second.getByTestId('save-coverage').click();
  await expect(second.getByTestId('coverage-error')).toContainText('Completion date cannot precede start date');

  // Moving back to in progress clears the completion and is recorded in the history.
  await page.getByTestId('coverage-row').first().getByLabel(/^Status of/).selectOption('in_progress');
  await page.getByTestId('coverage-row').first().getByTestId('save-coverage').click();
  await expect(page.getByTestId('coverage-pct')).toContainText('0.00% covered');
  await expect(page.getByTestId('coverage-history')).toContainText('completed → in progress');
});
