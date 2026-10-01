import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I09: generate a seating plan from the UI. Three sections are interleaved so benchmates never share a section,
// two paper sets alternate along every row, and a hall that is too small fails with the shortfall named.

test('seating plan: sections interleaved, sets alternate, shortfall reported', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'seating-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: sectionA } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const sections = [sectionA!.id as string];
  for (const name of ['B', 'C']) {
    const { data, error } = await owner$.rpc('create_section', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_name: name, p_capacity: 30 });
    expect(error).toBeNull();
    sections.push(data as string);
  }
  for (let i = 0; i < 12; i++) {
    const { data: st } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: `Seat Kid ${i + 1}`, p_dob: '2015-01-01', p_gender: 'male' });
    const { error } = await owner$.rpc('enrol_student', { p_section_id: sections[i % 3]!, p_student_id: st as string });
    expect(error).toBeNull();
  }

  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'MTH', name_en: 'Mathematics', name_ur: 'ریاضی' }).select('id').single();
  const { data: cs } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: subject!.id, p_weekly_periods: 5 });
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const { data: es } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs as string, p_components: [{ component: 'theory', max_marks: 100, pass_marks: 33 }] });
  const { data: hall, error: hallError } = await owner$.rpc('save_exam_hall', { p_campus_id: campusId, p_code: 'H1', p_name: 'Hall One', p_rows_count: 3, p_seats_per_row: 4 });
  expect(hallError).toBeNull();
  const { data: ds } = await owner$.rpc('create_datesheet', { p_campus_id: campusId, p_exam_term_id: term as string, p_title: 'First Term datesheet' });
  const { data: saved, error: slotError } = await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: es as string, p_exam_date: '2026-09-08', p_start_time: '09:00', p_end_time: '11:00', p_hall_id: hall as string });
  expect(slotError).toBeNull();
  const slotId = (saved as { slot_id: string }).slot_id;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/seating');
  await page.getByLabel('Paper sets').selectOption('2');
  await page.getByTestId('generate-plan').click();
  await expect(page.getByTestId('plan-message')).toContainText('12 candidates seated');
  await expect(page.getByTestId('plan-message')).toContainText('No adjacency violations');
  await expect(page.getByTestId('seat-taken')).toHaveCount(12);

  // The same checks on the stored allocations: one seat each, no benchmates from one section, sets alternate.
  const { data: alloc } = await db.from('exam_seat_allocation').select('row_no, seat_no, section_id, set_code, enrolment_id').eq('slot_id', slotId);
  expect(new Set(alloc!.map((a) => a.enrolment_id)).size).toBe(12);
  const at = new Map(alloc!.map((a) => [`${a.row_no}:${a.seat_no}`, a]));
  for (const a of alloc!) {
    const right = at.get(`${a.row_no}:${a.seat_no + 1}`);
    if (right) {
      expect(right.section_id).not.toBe(a.section_id);
      expect(right.set_code).not.toBe(a.set_code);
    }
  }

  // A thirteenth candidate does not fit the 12-seat hall.
  const { data: late } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: 'Late Admission', p_dob: '2015-01-01', p_gender: 'female' });
  const { error: lateError } = await owner$.rpc('enrol_student', { p_section_id: sections[0]!, p_student_id: late as string });
  expect(lateError).toBeNull();
  await page.reload();
  await page.getByTestId('generate-plan').click();
  await expect(page.getByTestId('plan-error')).toContainText('Not enough seats: 1 short');
  const { data: after } = await db.from('exam_seat_allocation').select('id').eq('slot_id', slotId);
  expect(after!.length).toBe(12);
});
