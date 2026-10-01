import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I05: request a paper from a board pattern. The request is a job card at once; a worker result that matches the
// pattern exactly becomes a paper, one that does not is rejected and nothing is stored; an unsigned callback is refused.
// The worker itself is outside this stack, so the test plays the worker through the same database function the signed
// callback route calls.

const questions = (longMarks: number) => [
  ...Array.from({ length: 12 }, (_, i) => ({ section_no: 1, question_no: i + 1, type: 'mcq', marks: 1, text: `MCQ ${i + 1}`, options: ['a', 'b', 'c', 'd'], answer: 'a', chapter: 'Ch.1', slo_code: `P-${i + 1}`, source_pages: [3], verbatim_ratio: 0 })),
  ...Array.from({ length: 9 }, (_, i) => ({ section_no: 2, question_no: i + 1, type: 'short', marks: 3, text: `Short ${i + 1}`, chapter: 'Ch.2', verbatim_ratio: 0 })),
  ...Array.from({ length: 2 }, (_, i) => ({ section_no: 3, question_no: i + 1, type: 'long', marks: longMarks, text: `Long ${i + 1}`, chapter: 'Ch.3', verbatim_ratio: 0 })),
];

test('request a paper, see the job card, accept a matching result and reject a mismatching one', async ({ page, request }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'paper-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  expect((await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 65, pass_marks: 23 }] })).error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/papers');
  await page.getByLabel('Pattern code').fill('FBISE-PHY-9');
  await page.getByLabel('Pattern name').fill('FBISE Physics IX');
  await expect(page.getByTestId('pattern-total')).toContainText('Total: 65 marks');
  await page.getByTestId('save-pattern').click();
  await expect(page.getByTestId('pattern-list')).toContainText('FBISE-PHY-9');

  // The wrong total is refused with the pattern's own total in the message.
  await page.getByLabel('Total marks').fill('70');
  await page.getByLabel('Chapters (comma separated)').fill('Ch.1, Ch.2, Ch.3, Ch.4');
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('request-error')).toContainText('totals 65 marks');

  await page.getByLabel('Total marks').fill('65');
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('job-card')).toHaveCount(1);
  const { data: job } = await db.from('paper_generation_job').select('id, status, total_marks').eq('tenant_id', tenant).single();
  expect(job!.total_marks).toBe(65);
  expect(['queued', 'running']).toContain(job!.status);

  // The worker answers with an exact 65-mark paper.
  const ok = await db.rpc('fn_ingest_generated_paper', { p_job_id: job!.id, p_payload: { sets: [{ set_code: 'A', title: 'Physics IX', questions: questions(13) }] } });
  expect(ok.error).toBeNull();
  await page.reload();
  await expect(page.getByTestId('job-status')).toHaveText('ready');
  await page.getByTestId('paper-link').click();
  await expect(page.getByTestId('paper-question')).toHaveCount(23);

  // A second request whose result is one mark short is rejected and stores nothing.
  await page.goto('/exams/papers');
  await page.getByLabel('Chapters (comma separated)').fill('Ch.1');
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('job-card')).toHaveCount(2);
  const { data: second } = await db.from('paper_generation_job').select('id').eq('tenant_id', tenant).neq('id', job!.id).single();
  await db.rpc('fn_ingest_generated_paper', { p_job_id: second!.id, p_payload: { sets: [{ set_code: 'A', title: 'x', questions: questions(12) }] } });
  await page.reload();
  await expect(page.locator('[data-testid="job-card"][data-status="pattern_mismatch"]')).toHaveCount(1);
  await expect(page.getByTestId('job-error')).toContainText('carries 12 marks, expected 13');
  const { data: papers } = await db.from('exam_paper').select('id, job_id').eq('tenant_id', tenant);
  expect(papers!.length).toBe(1);

  // An unsigned callback never reaches the database.
  const unsigned = await request.post('/api/exam-paper/callback', { data: { job_id: second!.id, payload: { sets: [] } } });
  expect(unsigned.status()).toBe(401);
});
