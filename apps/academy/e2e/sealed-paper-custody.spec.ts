import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I08: a published paper is sealed until its release window. A request before it is refused and recorded; inside
// the window a 15-minute signed link is issued under the set-coded filename and recorded; the Principal's log lists
// every attempt in time order; and nobody can delete an access record.

test('sealed until the window, every attempt audited, records cannot be deleted', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'sealed-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const { data: es } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 2, pass_marks: 1 }] });
  const { data: pattern } = await owner$.rpc('save_board_pattern', { p_code: 'MCQ2', p_name: 'Two MCQs', p_board: 'FBISE', p_sections: [{ no: 1, name: 'A', type: 'mcq', count: 2, marks_each: 1 }] });
  const { data: job } = await owner$.rpc('request_paper_generation', { p_exam_subject_id: es as string, p_board_pattern_id: pattern as string, p_chapters: ['Ch.1'], p_total_marks: 2, p_set_count: 1 });
  const ingest = await db.rpc('fn_ingest_generated_paper', {
    p_job_id: job as string,
    p_payload: { sets: [{ set_code: 'A', title: 'Physics', questions: [1, 2].map((n) => ({ section_no: 1, question_no: n, type: 'mcq', marks: 1, text: `Secret question ${n}`, options: ['a', 'b'], answer: 'a', chapter: 'Ch.1', verbatim_ratio: 0 })) }] },
  });
  expect(ingest.error).toBeNull();
  const { data: paper } = await db.from('exam_paper').select('id').eq('job_id', job as string).single();
  const paperId = paper!.id as string;
  expect((await owner$.rpc('publish_exam_paper', { p_paper_id: paperId })).error).toBeNull();

  // The exam is scheduled far ahead: the paper is sealed.
  const { data: ds } = await owner$.rpc('create_datesheet', { p_campus_id: campusId, p_exam_term_id: term as string, p_title: 'DS' });
  expect((await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: es as string, p_exam_date: '2031-01-15', p_start_time: '09:00', p_end_time: '11:00' })).error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto(`/exams/papers/${paperId}`);
  await expect(page.getByTestId('seal-status')).toContainText('Sealed until');
  await expect(page.getByTestId('paper-question')).toHaveCount(0);
  await page.getByTestId('render-files').click();
  await page.waitForResponse((r) => r.url().includes('/render') && r.request().method() === 'POST');

  // AC1: before the window the request is refused (403) and recorded.
  const early = await page.request.get(`/api/exam-papers/${paperId}/file?kind=paper&format=json`);
  expect(early.status()).toBe(403);
  expect((await early.json()).reason).toBe('sealed');
  await page.getByTestId('download-paper').click();
  await expect(page.getByTestId('download-error')).toContainText('sealed until');

  // AC2: the exam is now an hour away, inside the 120-minute window: a 15-minute link is issued.
  const soon = new Date(Date.now() + 60 * 60 * 1000).toISOString();
  const later = new Date(Date.now() + 180 * 60 * 1000).toISOString();
  await db.from('datesheet_slot').update({ start_at: soon, end_at: later }).eq('exam_subject_id', es as string);
  const ok = await page.request.get(`/api/exam-papers/${paperId}/file?kind=key&format=json`);
  expect(ok.status()).toBe(200);
  const issued = (await ok.json()) as { filename: string; expires_in: number; url: string };
  expect(issued.expires_in).toBe(900);
  expect(issued.filename).toBe('answer-key-physics-set-a.pdf');
  expect(issued.url).toContain('key-A.pdf');

  // AC3: the access log, oldest first, with outcomes.
  await page.goto(`/exams/papers/${paperId}`);
  await expect(page.getByTestId('seal-status')).toContainText('Released');
  await expect(page.getByTestId('paper-question')).toHaveCount(2);
  const outcomes = await page.getByTestId('access-row').evaluateAll((rows) => rows.map((r) => r.getAttribute('data-outcome')));
  expect(outcomes).toEqual(['denied', 'denied', 'granted']);
  const { data: records } = await db.from('exam_paper_access').select('user_role, outcome, kind').eq('exam_paper_id', paperId).order('accessed_at');
  expect(records!.map((r) => r.outcome)).toEqual(['denied', 'denied', 'granted']);
  expect(records![2]!.kind).toBe('key');
  expect(records![2]!.user_role).toBe('owner');

  // AC4: no delete, not even for the signed-in owner and not for the service role.
  const del = await owner$.from('exam_paper_access').delete().eq('exam_paper_id', paperId);
  expect(del.error).not.toBeNull();
  const adminDel = await db.from('exam_paper_access').delete().eq('exam_paper_id', paperId);
  expect(adminDel.error).not.toBeNull();
  const { data: after } = await db.from('exam_paper_access').select('id').eq('exam_paper_id', paperId);
  expect(after!.length).toBe(3);
});
