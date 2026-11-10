import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';
import { todayPk } from './support/today';

test('the hifz progress register lists lessons across halqas and filters by lesson type', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('hifz-progress-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const halqa = await must(db.from('halqa').insert({ tenant_id, campus_id, name: 'Halqa Umar' }).select('id').single());
  const student = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `H-${runId}`, name_en: 'Abdullah Khan', dob: '2014-01-01', gender: 'male', status: 'active' }).select('id').single());
  const lesson = { tenant_id, campus_id, halqa_id: halqa.id, student_id: student.id, lesson_date: todayPk(), recorded_by: owner.userId, mistakes: 0, tajweed_mistakes: 0 };
  const { error } = await db.from('hifz_lesson').insert([
    { ...lesson, lesson_type: 'sabaq', para_from: 3, para_to: 3, portion: 'Ruku 4', lines: 12, mistakes: 2, grade: 'good' },
    { ...lesson, lesson_type: 'manzil', para_from: 1, para_to: 2, portion: null, lines: null, grade: 'excellent' },
  ]);
  if (error) throw new Error(error.message);

  await signInAs(page, owner.email);
  await page.goto('/hifz/progress');
  const rows = page.getByTestId('hifz-lesson-row');
  await expect(rows).toHaveCount(2);
  await page.getByLabel('Lesson type').selectOption('sabaq');
  await page.getByRole('main').getByRole('button', { name: 'Search' }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Para 3, Ruku 4');
  await expect(rows.first()).toContainText('Halqa Umar');
});
