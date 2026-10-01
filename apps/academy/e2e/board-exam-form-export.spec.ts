import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-T12: board examination form export and fee reconciliation.
//
//   AC1  computed vs collected, with the students who have paid nothing named.
//   AC2  a Pre-Engineering candidate missing a mandatory subject blocks the
//        export and the missing subject code is named.
//   AC3  an improvement candidate is exported at the per-paper rate.
//   AC4  the fee schedule is effective-dated (covered in depth by the pgTAP).

test('the export is blocked on a missing mandatory subject, reconciles the fee, and produces the file once fixed', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(3, 'board-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: head } = await db.from('fee_head').select('id').eq('tenant_id', tenant).eq('code', 'BOARD_EXAM').maybeSingle();
  const boardHead =
    head ??
    (await db.from('fee_head').insert({ tenant_id: tenant, code: 'BOARD_EXAM', name_en: 'Board Exam Fee', name_ur: 'بورڈ امتحان فیس', default_frequency: 'one_time' }).select('id').single()).data!;

  const { data: enrolments } = await db.from('enrolment').select('id, student_id').in('id', challans.map((c) => c.enrolment_id));
  const kids = (enrolments ?? []).map((e) => ({ enrolmentId: e.id, studentId: e.student_id }));
  const [engineer, regular, improver] = kids;

  for (const [i, kid] of kids.entries()) {
    const { data: guardianId } = await owner$.rpc('fn_find_or_create_guardian', { p_name_en: `Guardian ${i}`, p_phone_e164: `+92300555010${i}` });
    await owner$.rpc('link_guardian', { p_student_id: kid.studentId, p_guardian_id: guardianId as string, p_relationship: 'mother', p_is_primary: true, p_receives_billing: true });
    const { error } = await owner$.rpc('record_consent', { p_student_id: kid.studentId, p_purpose_code: 'third_party_data_sharing', p_guardian_id: guardianId as string, p_decision: 'granted', p_channel: 'counter' });
    expect(error).toBeNull();
  }

  // The fee module billed the board fee on each child's challan; only the regular candidate paid.
  const billed = [265000, 265000, 190000];
  for (const [i, kid] of kids.entries()) {
    const challan = challans.find((c) => c.enrolment_id === kid.enrolmentId)!;
    await db.from('fee_challan_line').insert({ challan_id: challan.id, fee_head_id: boardHead.id, amount_paisa: billed[i]!, concession_paisa: 0, net_paisa: billed[i]!, line_type: 'charge' });
  }
  const regularChallan = challans.find((c) => c.enrolment_id === regular!.enrolmentId)!;
  const { data: payment } = await db.from('fee_payment').insert({ tenant_id: tenant, campus_id: campusId, enrolment_id: regular!.enrolmentId, amount_paisa: 265000, mode: 'cash' }).select('id').single();
  await db.from('fee_payment_allocation').insert({ payment_id: payment!.id, challan_id: regularChallan.id, fee_head_id: boardHead.id, amount_paisa: 265000 });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  // The board's schedule, through the screen.
  await page.goto('/exams/board-forms');
  await page.getByTestId('fee-year').fill('2026');
  await page.getByTestId('fee-per-candidate').fill('2650');
  await page.getByTestId('fee-effective').fill('2026-01-01');
  await page.getByTestId('fee-save').click();
  await expect(page.getByTestId('fee-table')).toContainText('PKR 2,650.00');
  await page.getByTestId('fee-category').selectOption('improvement');
  await page.getByTestId('fee-per-candidate').fill('0');
  await page.getByTestId('fee-per-paper').fill('1900');
  await page.getByTestId('fee-save').click();
  await expect(page.getByTestId('fee-table')).toContainText('PKR 1,900.00');

  const register = async (kid: { studentId: string }, category: string, group: string | null, roll: string, subjects: { subject_code: string; election: string }[]) => {
    const { error } = await owner$.rpc('save_exam_registration', {
      p_student_id: kid.studentId, p_session_id: session!.id, p_board_code: 'FBISE', p_session_year: 2026, p_session_date: '2026-04-15',
      p_candidate_category: category, p_group_code: group ?? undefined, p_roll_no: roll, p_subjects: subjects,
    });
    expect(error).toBeNull();
  };
  await register(engineer!, 'regular', 'PRE_ENG', '800001', [
    { subject_code: 'PHY', election: 'compulsory' },
    { subject_code: 'MTH', election: 'compulsory' },
  ]);
  await register(regular!, 'regular', 'PRE_ENG', '800002', [
    { subject_code: 'PHY', election: 'compulsory' },
    { subject_code: 'CHM', election: 'compulsory' },
    { subject_code: 'MTH', election: 'compulsory' },
  ]);
  await register(improver!, 'improvement', null, '800003', [{ subject_code: 'ENG', election: 'improvement' }]);

  await page.reload();
  await page.getByTestId('ex-year').fill('2026');
  await page.getByTestId('ex-check').click();
  await expect(page.getByTestId('readiness')).toBeVisible();

  // AC2: the missing Chemistry blocks, and is named.
  await expect(page.getByTestId('blocking-count')).toHaveText('1');
  await expect(page.locator('[data-testid^="error-"][data-testid$="MISSING_MANDATORY_SUBJECT"]')).toContainText('CHM');
  await expect(page.getByTestId('ex-generate')).toBeDisabled();

  // AC1: computed PKR 7,200 (2 x 2,650 + 1,900) against PKR 2,650 collected; two have paid nothing.
  await expect(page.getByTestId('reconciliation-headline')).toContainText('PKR 7,200 computed, PKR 2,650 collected');
  await expect(page.getByTestId('unpaid-list')).toContainText('Paid nothing (2)');

  // Fix the registration and re-check: now it can be generated.
  await register(engineer!, 'regular', 'PRE_ENG', '800001', [
    { subject_code: 'PHY', election: 'compulsory' },
    { subject_code: 'CHM', election: 'compulsory' },
    { subject_code: 'MTH', election: 'compulsory' },
  ]);
  await page.getByTestId('ex-check').click();
  await expect(page.getByTestId('blocking-count')).toHaveText('0');
  await expect(page.getByTestId('ex-generate')).toBeEnabled();
  await page.getByTestId('ex-generate').click();
  await expect(page.getByTestId('ex-download')).toBeVisible({ timeout: 60000 });

  // AC3 + the file: the improvement candidate is exported with only ENG, at PKR 1,900.
  const href = await page.getByTestId('ex-download').locator('a').getAttribute('href');
  const csv = await (await page.request.get(href!)).text();
  const improvementLine = csv.split('\r\n').find((l) => l.includes('800003'))!;
  expect(improvementLine).toContain(',ENG,');
  expect(improvementLine).toContain('1900.00');
  expect(csv).toContain('"Fee (PKR)"'.replace(/"/g, '') );
});
