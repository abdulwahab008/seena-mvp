import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H13: a parent sees covered / pending chapters only when the campus enables it, with an Urdu title where one exists.

test('a parent sees covered and pending chapters only when the campus shares them', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, challans } = await seedFeesTenant(1, 'psc-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { error: syllabusError } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: subject!.id, p_board: 'FBISE',
    p_units: [{ title: 'Motion', title_ur: 'حرکت', planned_periods: 8 }, { title: 'Force', planned_periods: 8 }, { title: 'Energy', planned_periods: 8 }],
  });
  expect(syllabusError).toBeNull();
  const { data: units } = await db.from('syllabus_unit').select('id, sequence').eq('tenant_id', tenant).order('sequence');
  // The owner (who may record coverage for any section) completes chapter 1.
  const { error: coverageError } = await owner$.rpc('set_syllabus_coverage', {
    p_section_id: section!.id, p_subject_id: subject!.id, p_unit_id: units![0]!.id, p_status: 'completed', p_started_on: '2026-09-01', p_completed_on: '2026-09-20', p_periods_used: 7,
  });
  expect(coverageError).toBeNull();

  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const email = `parent-${randomUUID().slice(0, 8)}@psc-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Syllabus Parent', phone_e164: '+923001237777', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);

  // Off by default: the parent is told it is not shared.
  await page.goto('/portal/syllabus');
  await expect(page.getByTestId('syllabus-not-shared')).toHaveText('This information is not shared by your school');
  await expect(page.getByTestId('syllabus-unit')).toHaveCount(0);

  // The Principal enables it for the campus.
  const { error: flagError } = await owner$.rpc('set_campus_feature_flag', { p_campus_id: campusId, p_flag_key: 'parent_syllabus_visibility', p_enabled: true });
  expect(flagError).toBeNull();
  await page.goto('/portal/syllabus');
  await expect(page.getByTestId('syllabus-unit')).toHaveCount(3);
  await expect(page.getByTestId('syllabus-unit').first()).toContainText('Covered on 2026-09-20');
  await expect(page.getByTestId('syllabus-unit').nth(1)).toContainText('Pending');
  await expect(page.locator('body')).not.toContainText('periods');

  // Urdu where a title exists, English otherwise.
  await page.getByTestId('language-toggle').click();
  await expect(page.getByTestId('syllabus-unit').first()).toContainText('حرکت');
  await expect(page.getByTestId('syllabus-unit').nth(1)).toContainText('Force');
});
