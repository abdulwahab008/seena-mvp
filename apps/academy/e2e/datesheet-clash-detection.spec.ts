import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I03: building a datesheet. A pupil registered for two overlapping papers blocks the save and the
// GR numbers are listed; a non-overlapping slot saves; a hall that is too small raises a warning.

test('overlapping papers with shared candidates are blocked; a hall too small is a warning', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(3, 'datesheet-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: students } = await db.from('student').select('gr_number').eq('tenant_id', tenant).order('gr_number');
  expect(students!.length).toBe(3);

  const subject = async (code: string, name: string) => {
    const { data } = await db.from('subject').insert({ tenant_id: tenant, code, name_en: name, name_ur: name }).select('id').single();
    const { data: cs, error } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: data!.id, p_weekly_periods: 5 });
    expect(error).toBeNull();
    return cs as string;
  };
  const csMath = await subject('MTH', 'Mathematics');
  const csSci = await subject('SCI', 'Science');
  const { data: term, error: termError } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  expect(termError).toBeNull();
  expect(term).toBeTruthy();
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const components = [{ component: 'theory', max_marks: 100, pass_marks: 33 }];
  expect((await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: csMath, p_components: components })).error).toBeNull();
  expect((await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: csSci, p_components: components })).error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/datesheet');
  await page.getByTestId('create-datesheet').click();
  await expect(page.getByTestId('datesheet-status')).toHaveText('draft');

  await page.getByLabel('Hall code').fill('H1');
  await page.getByLabel('Hall name').fill('Small Hall');
  await page.getByLabel('Rows').fill('1');
  await page.getByLabel('Seats per row').fill('2');
  await page.getByTestId('save-hall').click();
  await expect(page.getByTestId('hall-list')).toContainText('Small Hall');

  // First paper: saves, 3 candidates against a hall of 2 -> a capacity warning, not a block.
  await page.getByLabel('Paper').selectOption({ index: 0 });
  await page.getByLabel('Date').fill('2026-09-08');
  await page.getByLabel('Start').fill('09:00');
  await page.getByLabel('End').fill('11:00');
  await page.getByLabel('Hall', { exact: true }).selectOption({ index: 1 });
  await page.getByTestId('save-slot').click();
  await expect(page.getByTestId('slot-row')).toHaveCount(1);
  await expect(page.getByTestId('slot-list')).toContainText('capacity short by 1');

  // Second paper overlaps and every class-1 pupil sits both: blocked, with the GR numbers.
  await page.getByLabel('Paper').selectOption({ index: 1 });
  await page.getByLabel('Start').fill('10:00');
  await page.getByLabel('End').fill('12:00');
  await page.getByLabel('Hall', { exact: true }).selectOption({ index: 0 });
  await page.getByTestId('save-slot').click();
  await expect(page.getByTestId('slot-error')).toContainText('Clash');
  await expect(page.getByTestId('slot-error')).toContainText(students![0]!.gr_number);
  await expect(page.getByTestId('slot-row')).toHaveCount(1);

  // Moved after the first paper ends: saves.
  await page.getByLabel('Start').fill('11:00');
  await page.getByLabel('End').fill('13:00');
  await page.getByTestId('save-slot').click();
  await expect(page.getByTestId('slot-row')).toHaveCount(2);
});
