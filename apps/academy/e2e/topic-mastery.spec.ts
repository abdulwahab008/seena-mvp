import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J07: topic mastery from per-question marks.
//
//   AC1  per-chapter percentages, weakest first ("Ch.3 Motion 42%, Ch.1 Measurements 88%").
//   AC2  a paper entered as a total: no breakdown, and the screen says why.
//   AC3  a section chapter below 50% is a re-teach candidate.
//   AC4  a chapter with fewer than 3 questions carries a low-confidence marker.

test('a teacher defines a paper\'s chapters, captures marks, and reads the mastery that comes out', async ({ page }) => {
  test.setTimeout(150000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(2, 'mastery-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subjects } = await db
    .from('subject')
    .insert([
      { tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' },
      { tenant_id: tenant, code: 'CHM', name_en: 'Chemistry', name_ur: 'کیمیا' },
    ])
    .select('id, code');
  const subj = Object.fromEntries((subjects ?? []).map((s) => [s.code, s.id]));
  const { data: classSubjects } = await db
    .from('class_subject')
    .insert(['PHY', 'CHM'].map((c) => ({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: section!.class_level_id, subject_id: subj[c]!, weekly_periods: 5 })))
    .select('id, subject_id');
  const { data: term } = await db
    .from('exam_term')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, code: 'T1', name: 'Final Term', sequence: 1, weight_bp: 10000, counts_toward_annual: true, status: 'active' })
    .select('id')
    .single();
  const examSubjects: Record<string, string> = {};
  for (const cs of classSubjects ?? []) {
    const { data: es } = await db.from('exam_subject').insert({ tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, class_subject_id: cs.id }).select('id').single();
    await db.from('exam_subject_component').insert({ tenant_id: tenant, exam_subject_id: es!.id, component: 'theory', max_marks: 100, pass_marks: 0, sequence: 1 });
    examSubjects[cs.subject_id] = es!.id;
  }

  const { data: enrolments } = await db.from('enrolment').select('id, student:student_id(name_en, gr_number)').in('id', challans.map((c) => c.enrolment_id));
  const kids = (enrolments ?? []).map((e) => {
    const s = Array.isArray(e.student) ? e.student[0]! : e.student!;
    return { enrolmentId: e.id, gr: s.gr_number, name: s.name_en };
  });
  const [first] = kids;
  // Chemistry has a total and no per-question marks.
  await db.from('subject_result').insert({
    tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, section_id: section!.id, exam_subject_id: examSubjects[subj.CHM!]!,
    enrolment_id: first!.enrolmentId, subject_id: subj.CHM!, obtained: 61, max_marks: 100, pct: 61, is_pass: true,
  });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  // Define the scheme: Ch.1 (3 questions, 50 marks), Ch.2 (2 questions, 20), Ch.3 (3 questions, 30).
  await page.goto('/exams/mastery/capture');
  await page.getByTestId('cap-section').selectOption(section!.id);
  await page.getByTestId('cap-paper').selectOption({ label: 'Physics — Final Term' });
  await page.getByTestId('cap-open').click();
  await expect(page.getByTestId('scheme-editor')).toBeVisible();
  const scheme: [string, string, string][] = [
    ['20', '1', 'Measurements'], ['15', '1', 'Measurements'], ['15', '1', 'Measurements'],
    ['10', '2', 'Heat'], ['10', '2', 'Heat'],
    ['10', '3', 'Motion'], ['10', '3', 'Motion'], ['10', '3', 'Motion'],
  ];
  for (let i = 1; i < scheme.length; i += 1) await page.getByTestId('add-question').click();
  for (const [i, [marks, chapter, title]] of scheme.entries()) {
    await page.getByTestId(`q-max-${i + 1}`).fill(marks);
    await page.getByTestId(`q-chapter-${i + 1}`).fill(chapter);
    await page.getByTestId(`q-title-${i + 1}`).fill(title);
  }
  await page.getByTestId('save-scheme').click();
  await expect(page.getByTestId('marks-grid')).toBeVisible();

  // First student: Ch.1 44/50 = 88%, Ch.2 15/20 = 75%, Ch.3 11/30 = 37%.
  const marks = [18, 13, 13, 10, 5, 4, 4, 3];
  for (const [i, m] of marks.entries()) await page.getByTestId(`cell-${first!.gr}-${i + 1}`).fill(String(m));
  await page.getByTestId('save-marks').click();
  await expect.poll(async () => (await db.from('question_response_mark').select('id').eq('tenant_id', tenant)).data?.length).toBe(8);

  await page.goto(`/exams/mastery?section=${section!.id}&student=${first!.enrolmentId}`);
  const summary = page.getByTestId('student-summary');
  await expect(summary).toContainText('Ch.3 Motion 37%, Ch.2 Heat 75%, Ch.1 Measurements 88%');
  // AC3: the section's Ch.3 is below 50% -> re-teach.
  await expect(page.getByTestId('reteach-Ch.3 Motion')).toBeVisible();
  await expect(page.getByTestId('reteach-Ch.1 Measurements')).toHaveCount(0);
  // AC4: Ch.2 has two questions.
  await expect(page.getByTestId('lowconf-Ch.2 Heat')).toBeVisible();
  await expect(page.getByTestId('lowconf-Ch.1 Measurements')).toHaveCount(0);
  // AC2: Chemistry was a total.
  await expect(page.getByTestId('uncaptured-note')).toContainText('per-question data was not captured');
  await expect(page.getByTestId('uncaptured-note')).toContainText('Chemistry');
});
