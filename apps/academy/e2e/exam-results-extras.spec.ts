import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

async function seedTermResults(label: string) {
  const seed = await seedHrTenant(label);
  const { db, tenantId: tenant_id, campusId: campus_id, runId } = seed;
  const one = async <T,>(q: PromiseLike<{ data: T | null; error: { message: string } | null }>, what: string): Promise<T> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(`${what}: ${error?.message}`);
    return data;
  };
  const session = await one(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single(), 'session');
  const level = await one(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single(), 'level');
  const base = { tenant_id, campus_id, session_id: session.id };
  const section = await one(db.from('class_section').insert({ ...base, class_level_id: level.id, name: 'A', capacity: 30 }).select('id').single(), 'section');
  const term = await one(db.from('exam_term').insert({ ...base, code: 'MID', name: 'Mid Term', sequence: 1 }).select('id').single(), 'term');
  const subject = await one(db.from('subject').insert({ tenant_id, code: 'MATH', name_en: 'Mathematics' }).select('id').single(), 'subject');
  const classSubject = await one(db.from('class_subject').insert({ ...base, class_level_id: level.id, subject_id: subject.id, weekly_periods: 5 }).select('id').single(), 'class subject');
  const examSubject = await one(db.from('exam_subject').insert({ tenant_id, campus_id, exam_term_id: term.id, class_subject_id: classSubject.id }).select('id').single(), 'exam subject');

  const kids = [
    { name: 'Ayesha', marks: 92, rank: 1, phone: '+923001110001' },
    { name: 'Bilal', marks: 20, rank: 2, phone: '+923001110002' },
  ];
  for (const k of kids) {
    const student = await one(db.from('student').insert({ tenant_id, campus_id, gr_number: `${k.name}-${runId}`, name_en: k.name, dob: '2015-01-01', gender: 'female', status: 'active' }).select('id').single(), 'student');
    const enrol = await one(db.from('enrolment').insert({ ...base, class_level_id: level.id, section_id: section.id, student_id: student.id, roll_no: k.rank, status: 'active' }).select('id').single(), 'enrolment');
    const guardian = await one(db.from('guardian').insert({ tenant_id, name_en: `Parent of ${k.name}`, phone_e164: k.phone }).select('id').single(), 'guardian');
    await one(db.from('student_guardian').insert({ tenant_id, student_id: student.id, guardian_id: guardian.id, relationship: 'mother', is_primary: true, receives_academic: true, receives_billing: true }).select('student_id').single(), 'link');
    await one(db.from('subject_result').insert({ tenant_id, campus_id, exam_term_id: term.id, section_id: section.id, exam_subject_id: examSubject.id, enrolment_id: enrol.id, subject_id: subject.id, obtained: k.marks, max_marks: 100, is_pass: k.marks >= 33 }).select('id').single(), 'result');
    await one(db.from('result_position').insert({ tenant_id, campus_id, exam_term_id: term.id, class_level_id: level.id, section_id: section.id, enrolment_id: enrol.id, total_obtained: k.marks, total_max: 100, rank_in_section: k.rank, rank_in_class: k.rank, ranked_out_of: 2, ranked_out_of_class: 2, is_ranked: true, rank_policy: 'include_all' }).select('id').single(), 'position');
  }
  return { ...seed, sectionId: section.id, termId: term.id, runId };
}

test('the exam controller reads the tabulation, merit and failure lists, sends results, and records a re-check, a board result and behaviour', async ({ page }) => {
  const { mkUser, sectionId, termId, runId } = await seedTermResults('results-extras-e2e');
  const controller = await mkUser('exams', 'exam_controller');
  await signInAs(page, controller.email);
  const q = `section=${sectionId}&term=${termId}`;

  await page.goto(`/exams/tabulation?${q}`);
  await expect(page.getByTestId('tabulation-row')).toHaveCount(2);
  await page.getByRole('link', { name: 'Failure list', exact: true }).click();
  await expect(page.getByTestId('tabulation-row')).toHaveCount(1);
  await expect(page.getByTestId('tabulation-row')).toContainText('Bilal');
  await page.getByRole('link', { name: 'Merit list', exact: true }).click();
  await expect(page.getByTestId('tabulation-row').first()).toContainText('Ayesha');
  await page.getByRole('button', { name: 'Send results by SMS' }).click();
  await page.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(page.getByText('Queued 2 result messages.')).toBeVisible();

  await page.goto(`/exams/rechecks?term=${termId}`);
  await page.getByLabel('Student').selectOption({ label: `Bilal (Bilal-${runId})` });
  await page.getByLabel('Subject').selectOption({ label: 'Mathematics' });
  await page.getByLabel('Fee (PKR)').fill('500');
  await page.getByLabel('Reason').fill('Question 4 not marked');
  await page.getByRole('button', { name: 'Record request' }).click();
  await expect(page.getByText('Re-check recorded.')).toBeVisible();
  await page.getByRole('button', { name: 'Record outcome' }).click();
  await page.getByLabel('Corrected marks (if changed)').fill('34');
  await page.getByRole('button', { name: 'Marks changed' }).click();
  await expect(page.getByTestId('recheck-row')).toContainText('20 → 34');

  await page.goto('/exams/external-results');
  await page.getByLabel('GR number').fill(`Ayesha-${runId}`);
  await page.getByLabel('Board').fill('BISE Lahore');
  await page.getByLabel('Exam').fill('SSC Part I');
  await page.getByLabel('Roll number').fill('123456');
  await page.getByLabel('Marks obtained').fill('480');
  await page.getByLabel('Total marks').fill('550');
  await page.getByLabel('Grade').fill('A');
  await page.getByRole('button', { name: 'Save result' }).click();
  await expect(page.getByTestId('external-result-row')).toContainText('480/550');

  await page.goto(`/exams/behaviour?${q}`);
  await page.getByRole('button', { name: 'Add the standard traits' }).click();
  await page.getByLabel('Punctuality for Ayesha').selectOption('A');
  await page.getByRole('button', { name: 'Save ratings' }).click();
  await expect(page.getByText('Ratings saved.')).toBeVisible();
  await page.reload();
  await expect(page.getByLabel('Punctuality for Ayesha')).toHaveValue('A');
});
