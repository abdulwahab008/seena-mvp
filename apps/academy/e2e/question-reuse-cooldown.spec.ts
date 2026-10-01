import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I06: a Mid Term draft reuses two questions the class saw in the First Term. The builder flags them amber with
// "used 1 term ago" and the count; in block mode publication is refused until an override reason is recorded, and the
// override (who and why) is shown against the paper.

const paperOf = (texts: string[]) => ({ sets: [{ set_code: 'A', title: 'Paper', questions: texts.map((t, i) => ({ section_no: 1, question_no: i + 1, type: 'mcq', marks: 1, text: t, options: ['a', 'b'], answer: 'a', chapter: 'Ch.1', verbatim_ratio: 0 })) }] });

test('reused questions are flagged; block mode needs an override reason that is recorded', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'cooldown-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: t1 } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 50 });
  const { data: t2 } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T2', p_name: 'Mid Term', p_sequence: 2, p_weight_pct: 50 });
  expect((await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId })).error).toBeNull();
  const comp = [{ component: 'theory', max_marks: 3, pass_marks: 1 }];
  const { data: es1 } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: t1 as string, p_class_subject_id: cs as string, p_components: comp });
  const { data: es2 } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: t2 as string, p_class_subject_id: cs as string, p_components: comp });
  const { data: pattern } = await owner$.rpc('save_board_pattern', { p_code: 'P3', p_name: 'Three MCQs', p_board: 'FBISE', p_sections: [{ no: 1, name: 'A', type: 'mcq', count: 3, marks_each: 1 }] });

  const makePaper = async (examSubject: string, texts: string[]) => {
    const { data: job, error } = await owner$.rpc('request_paper_generation', { p_exam_subject_id: examSubject, p_board_pattern_id: pattern as string, p_chapters: ['Ch.1'], p_total_marks: 3, p_set_count: 1 });
    expect(error).toBeNull();
    const ingest = await db.rpc('fn_ingest_generated_paper', { p_job_id: job as string, p_payload: paperOf(texts) });
    expect(ingest.error).toBeNull();
    const { data: paper } = await db.from('exam_paper').select('id').eq('job_id', job as string).single();
    return paper!.id as string;
  };
  const firstTerm = await makePaper(es1 as string, ['What is velocity?', 'Define force.', 'State Newton\'s first law.']);
  expect((await owner$.rpc('publish_exam_paper', { p_paper_id: firstTerm })).error).toBeNull();
  const midTerm = await makePaper(es2 as string, ['What is velocity?', 'define   FORCE.', 'What is a vector quantity?']);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  // Block mode: set from the settings card.
  await page.goto('/exams/papers');
  await page.getByLabel('When a flagged paper is published').selectOption('block');
  await page.getByTestId('save-cooldown').click();
  await expect.poll(async () => (await db.from('exam_settings').select('cooldown_mode').eq('campus_id', campusId).single()).data?.cooldown_mode).toBe('block');

  await page.goto(`/exams/papers/${midTerm}`);
  await expect(page.getByTestId('flag-summary')).toContainText('2 questions flagged');
  await expect(page.locator('[data-testid="paper-question"][data-flagged="true"]')).toHaveCount(2);
  await expect(page.getByTestId('reuse-flag').first()).toContainText('Used 1 term ago (First Term)');
  await expect(page.locator('[data-testid="paper-question"][data-flagged="false"]')).toHaveCount(1);

  // Refused without a reason; accepted with one, and the override is on the record.
  await page.getByTestId('publish-paper').click();
  await expect(page.getByTestId('publish-paper-error')).toContainText('Enter an override reason');
  await expect(page.getByTestId('paper-status')).toHaveText('draft');
  await page.getByLabel(/Override reason/).fill('HOD wants the board-style questions repeated');
  await page.getByTestId('publish-paper').click();
  await expect(page.getByTestId('paper-status')).toHaveText('published');
  await expect(page.getByTestId('override-record')).toContainText('HOD wants the board-style questions repeated');
  await expect(page.getByTestId('override-record')).toContainText('2 flagged questions');
});
