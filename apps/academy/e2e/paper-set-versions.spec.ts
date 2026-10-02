import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I07: build Set A and Set B from the question bank. Blueprint-identical sets, an honest failure when the bank is
// too thin, and an answer key whose download name carries its own set code.

test('build two sets from the bank, compare them and download the Set B key', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'sets-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  expect((await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 4, pass_marks: 1 }] })).error).toBeNull();
  expect((await owner$.rpc('save_board_pattern', { p_code: 'MCQ4', p_name: 'Four MCQs', p_board: 'FBISE', p_sections: [{ no: 1, name: 'Section A', type: 'mcq', count: 4, marks_each: 1 }] })).error).toBeNull();
  const bank = ['Ch.1', 'Ch.2'].flatMap((chapter) =>
    Array.from({ length: 4 }, (_, i) => ({ tenant_id: tenant, campus_id: campusId, subject_id: subject!.id, class_level_id: level!.id, chapter, marks: 1, question_type: 'mcq', question_text: `Bank ${chapter} question ${i + 1}`, options: ['a', 'b'], answer: 'a' })),
  );
  expect((await db.from('question_bank_item').insert(bank)).error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/papers');

  // AC3: a chapter the bank has nothing for fails by name; no sets are built.
  await page.locator('#setsChapters').fill('Ch.1, Ch.9');
  await page.getByTestId('build-sets').click();
  await expect(page.getByTestId('build-sets-error')).toContainText('Not enough usable questions in the bank for Ch.9 MCQ');
  expect((await db.from('exam_paper').select('id').eq('tenant_id', tenant)).data).toHaveLength(0);

  // AC1: two sets with one blueprint.
  await page.locator('#setsChapters').fill('Ch.1, Ch.2');
  await page.getByTestId('build-sets').click();
  await expect(page.getByTestId('paper-link')).toHaveCount(2);
  const { data: papers } = await db.from('exam_paper').select('id, set_code').eq('tenant_id', tenant).order('set_code');
  expect(papers!.map((p) => p.set_code)).toEqual(['A', 'B']);
  const { data: items } = await db.from('exam_paper_item').select('paper_id, chapter, marks').in('paper_id', papers!.map((p) => p.id));
  for (const p of papers!) {
    const own = items!.filter((i) => i.paper_id === p.id);
    expect(own.reduce((s, i) => s + i.marks, 0)).toBe(4);
    expect(own.filter((i) => i.chapter === 'Ch.2')).toHaveLength(2);
  }

  // The second build is refused without "replace".
  await page.getByTestId('build-sets').click();
  await expect(page.getByTestId('build-sets-error')).toContainText('already has draft sets');

  // Compare on Set B's page.
  const setB = papers!.find((p) => p.set_code === 'B')!;
  await page.goto(`/exams/papers/${setB.id}`);
  await expect(page.getByTestId('set-link')).toHaveCount(2);
  await expect(page.getByTestId('set-divergence')).toContainText('shares 0%');
  await expect(page.getByTestId('set-report').locator('tbody tr')).toHaveCount(2);

  // AC4: the key downloads as this set's own file.
  // Rendering is asynchronous (two PDFs through the renderer): wait for the POST to finish, otherwise the key
  // is requested before it exists in the bucket.
  const rendered = page.waitForResponse((r) => r.url().includes(`/api/exam-papers/${setB.id}/render`) && r.request().method() === 'POST');
  await page.getByTestId('render-files').click();
  expect((await rendered).status()).toBe(200);
  await expect(page.getByTestId('download-key')).toBeVisible();
  const key = await page.request.get(`/api/exam-papers/${setB.id}/file?kind=key&format=json`);
  expect(key.status()).toBe(200);
  const issued = (await key.json()) as { filename: string; set_code: string; url: string; expires_in: number };
  expect(issued.filename).toBe('answer-key-physics-set-b.pdf');
  expect(issued.set_code).toBe('B');
  expect(issued.expires_in).toBe(900);
  expect(issued.url).toContain('key-B.pdf');
});
