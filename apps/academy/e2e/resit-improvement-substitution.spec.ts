import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J14: re-sit and improvement attempts kept beside the original.
//
//   AC1  original 28/100 (fail), re-sit 61, capped_at_pass with pass mark 33:
//        33 is published annotated R, 61 stays visible in the internal record.
//   AC4  an unexcused absentee is not eligible until a Principal records an
//        exception.

test('a failed paper is re-sat and published capped at the pass mark; an exception unlocks an absentee', async ({ page }) => {
  test.setTimeout(150000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(2, 'resit-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'MTH', name_en: 'Maths', name_ur: 'ریاضی' }).select('id').single();
  const { data: classSubject } = await db
    .from('class_subject')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: section!.class_level_id, subject_id: subject!.id, weekly_periods: 5 })
    .select('id')
    .single();
  const { data: term } = await db
    .from('exam_term')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, code: 'T1', name: 'Final Term', sequence: 1, weight_bp: 10000, counts_toward_annual: true, status: 'active' })
    .select('id')
    .single();
  const { data: examSubject } = await db.from('exam_subject').insert({ tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, class_subject_id: classSubject!.id }).select('id').single();
  await db.from('exam_subject_component').insert({ tenant_id: tenant, exam_subject_id: examSubject!.id, component: 'theory', max_marks: 100, pass_marks: 33, sequence: 1 });

  const { data: enrolments } = await db.from('enrolment').select('id, student:student_id(name_en, gr_number)').in('id', challans.map((c) => c.enrolment_id));
  const info = (enrolments ?? []).map((e) => {
    const s = Array.isArray(e.student) ? e.student[0]! : e.student!;
    return { enrolmentId: e.id, gr: s.gr_number };
  });
  const [failed, absent] = info;

  const { error: markError } = await db.from('mark_entry').insert({
    tenant_id: tenant, campus_id: campusId, exam_subject_id: examSubject!.id, enrolment_id: failed!.enrolmentId,
    component_code: 'theory', marks_obtained: 28, status: 'locked',
  });
  expect(markError).toBeNull();
  await db.from('exam_attendance').insert({ tenant_id: tenant, campus_id: campusId, exam_subject_id: examSubject!.id, enrolment_id: absent!.enrolmentId, status: 'absent', reason: 'unauthorised' });
  const result = (enrolmentId: string, obtained: number, symbol: string | null) => ({
    tenant_id: tenant, campus_id: campusId, exam_term_id: term!.id, section_id: section!.id, exam_subject_id: examSubject!.id,
    enrolment_id: enrolmentId, subject_id: subject!.id, obtained, max_marks: 100, pct: obtained, is_pass: false, report_symbol: symbol,
  });
  const { error: resultError } = await db.from('subject_result').insert([result(failed!.enrolmentId, 28, null), result(absent!.enrolmentId, 0, 'AB')]);
  expect(resultError).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/resits');
  await page.getByTestId('generate-list').click();
  await expect(page.getByTestId('resit-table')).toBeVisible();
  await expect(page.getByTestId(`resit-eligibility-${failed!.gr}-Maths`)).toContainText('Eligible');
  await expect(page.getByTestId(`resit-eligibility-${failed!.gr}-Maths`)).toContainText('Failed the paper');
  await expect(page.getByTestId(`resit-eligibility-${absent!.gr}-Maths`)).toContainText('Not eligible');

  // AC4: the Principal's exception makes the absentee eligible.
  await page.getByTestId(`grant-${absent!.gr}-Maths`).click();
  await page.getByTestId('exception-reason').fill('Bereavement in the family on the day');
  await page.getByTestId('exception-save').click();
  await expect(page.getByTestId(`resit-eligibility-${absent!.gr}-Maths`)).toContainText('Principal exception');

  // AC1: the re-sit publishes 33, annotated R, with the raw 61 beside it.
  await page.getByTestId(`record-${failed!.gr}-Maths`).click();
  await page.getByTestId('attempt-marks').fill('61');
  await page.getByTestId('attempt-date').fill('2026-08-12');
  await page.getByTestId('attempt-save').click();
  await expect(page.getByTestId(`resit-published-${failed!.gr}-Maths`)).toContainText('33 of 100');
  await expect(page.getByTestId(`resit-published-${failed!.gr}-Maths`)).toContainText('raw 61');
  await expect(page.getByTestId(`resit-attempt-${failed!.gr}-2`)).toContainText('61');

  const { data: published } = await db.from('subject_result').select('obtained, report_symbol, is_pass').eq('enrolment_id', failed!.enrolmentId).single();
  expect(Number(published!.obtained)).toBe(33);
  expect(published!.report_symbol).toBe('R');
  expect(published!.is_pass).toBe(true);
  const { data: attempt } = await db.from('exam_attempt').select('obtained, attempt_no, attempt_type').eq('enrolment_id', failed!.enrolmentId).single();
  expect(Number(attempt!.obtained)).toBe(61);
  expect(attempt!.attempt_no).toBe(2);
  expect(attempt!.attempt_type).toBe('resit');
});
