import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the failure list shows students who failed a subject with their marks', async ({ page }) => {
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(2, 'failures-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'MTH', name_en: 'Maths' }).select('id').single();
  const { data: classSubject } = await db
    .from('class_subject')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: section!.class_level_id, subject_id: subject!.id, weekly_periods: 5 })
    .select('id')
    .single();
  const { data: term } = await db
    .from('exam_term')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, code: 'MID', name: 'Mid Term', sequence: 1, weight_bp: 0, counts_toward_annual: false, status: 'active' })
    .select('id')
    .single();
  const { data: es } = await db.from('exam_subject').insert({ tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, class_subject_id: classSubject!.id }).select('id').single();
  const base = { tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, section_id: section!.id, exam_subject_id: es!.id, subject_id: subject!.id, max_marks: 100 };
  const { error } = await db.from('subject_result').insert([
    { ...base, enrolment_id: challans[0]!.enrolment_id, obtained: 21, pct: 21, is_pass: false },
    { ...base, enrolment_id: challans[1]!.enrolment_id, obtained: 77, pct: 77, is_pass: true },
  ]);
  expect(error).toBeNull();
  const { data: failingEnrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const { data: failingStudent } = await db.from('student').select('name_en').eq('id', failingEnrolment!.student_id).single();
  const failingName: string = failingStudent!.name_en;

  await signInAs(page, email);
  await page.goto('/exams/failures');
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Pass rate50%');
  await expect(page.getByTestId('failure-row')).toHaveCount(1);
  await expect(page.getByTestId('failure-row')).toContainText(failingName);
  await expect(page.getByTestId('failure-row')).toContainText('Maths 21/100');
});
