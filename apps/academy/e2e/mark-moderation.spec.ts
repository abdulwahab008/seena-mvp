import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I15: the exam controller moderates a section: an over-cap adjustment and a thin reason are refused, a valid +4 is
// applied (the candidate who hits the component maximum is listed), a second moderation is blocked until the first is
// reversed, and approved marks cannot be moderated.

test('moderate a section within the cap, once, before approval', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'moderation-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const { data: es } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 65, pass_marks: 23 }] });

  const enrolments: string[] = [];
  for (let i = 1; i <= 4; i++) {
    const { data: st } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: `Mod Kid ${i}`, p_dob: '2015-01-01', p_gender: 'male' });
    const { data: en, error } = await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: st as string });
    expect(error).toBeNull();
    enrolments.push(en as string);
  }
  const marks = [25, 25, 25, 64];
  const { error: markError } = await db.from('mark_entry').insert(enrolments.map((enrolment_id, i) => ({ tenant_id: tenant, campus_id: campusId, exam_subject_id: es as string, enrolment_id, component_code: 'theory', marks_obtained: marks[i]!, status: 'draft' })));
  expect(markError).toBeNull();
  const { data: capGr } = await db.from('enrolment').select('student:student_id(gr_number)').eq('id', enrolments[3]!).single();
  const capGrNumber = (Array.isArray(capGr!.student) ? capGr!.student[0] : capGr!.student)!.gr_number as string;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/moderation');
  await expect(page.getByTestId('moderation-context')).toContainText('Section mean');
  await expect(page.getByTestId('moderation-context')).toContainText('Cap: ±5 marks');

  // AC2: +9 against a cap of 5 is refused and the cap is named.
  await page.getByLabel(/Adjustment/).fill('9');
  await page.getByLabel(/Reason/).fill('paper harder than blueprint, Q7 outside prescribed chapters');
  await page.getByTestId('apply-moderation').click();
  await expect(page.getByTestId('moderation-error')).toContainText('5 marks');

  // A thin reason never reaches the database.
  await page.getByLabel(/Adjustment/).fill('4');
  await page.getByLabel(/Reason/).fill('too hard');
  await page.getByTestId('apply-moderation').click();
  await expect(page.getByTestId('moderation-error')).toContainText('at least 20 characters');

  // AC1: +4 with a reason; the candidate at 64 hits the maximum of 65 and is listed.
  await page.getByLabel(/Reason/).fill('paper harder than blueprint, Q7 outside prescribed chapters');
  await page.getByTestId('apply-moderation').click();
  await expect(page.getByTestId('moderation-result')).toContainText('4 present candidates were moderated');
  await expect(page.getByTestId('capped-list')).toContainText(capGrNumber);
  const { data: after } = await db.from('mark_entry').select('marks_obtained').eq('exam_subject_id', es as string).order('marks_obtained');
  expect(after!.map((m) => Number(m.marks_obtained))).toEqual([29, 29, 29, 65]);

  // AC3: the section is moderated once; reversal is explicit.
  await page.reload();
  await expect(page.getByTestId('moderation-applied')).toBeVisible();
  await expect(page.getByTestId('apply-moderation')).toHaveCount(0);
  await expect(page.getByTestId('moderation-row')).toHaveCount(1);
  await page.getByLabel('Reason for reversing').fill('Applied to the wrong section by mistake');
  await page.getByTestId('reverse-moderation').click();
  await expect(page.locator('[data-testid="moderation-row"][data-reversed="true"]')).toHaveCount(1);
  const { data: restored } = await db.from('mark_entry').select('marks_obtained').eq('exam_subject_id', es as string).order('marks_obtained');
  expect(restored!.map((m) => Number(m.marks_obtained))).toEqual([25, 25, 25, 64]);
  await expect(page.getByTestId('apply-moderation')).toBeVisible();

  // AC4: once a mark is approved the section cannot be moderated.
  await db.from('mark_entry').update({ status: 'approved' }).eq('enrolment_id', enrolments[0]!);
  await page.reload();
  await expect(page.getByTestId('moderation-approved')).toContainText('break-glass');
  await expect(page.getByTestId('apply-moderation')).toHaveCount(0);
});
