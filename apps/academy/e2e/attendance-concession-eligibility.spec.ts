import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-G17: a threshold withholds a concession, and a later attendance correction raises an adjustment task.

test('attendance below the threshold withholds the concession and a correction raises a task', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(1, 'elig-e2e');
  const enrolmentId = challans[0]!.enrolment_id;
  const { data: head } = await db.from('fee_head').select('id').eq('tenant_id', tenant).eq('code', 'TUITION').single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: scheme, error: schemeError } = await owner$.rpc('create_concession_scheme', {
    p_code: 'MERITE2E', p_name_en: 'Merit E2E', p_name_ur: 'میرٹ', p_calc_type: 'percentage', p_value: 50, p_applicable_head_ids: [head!.id], p_category: 'merit',
  });
  expect(schemeError).toBeNull();
  const monthStart = new Date().toISOString().slice(0, 7) + '-01';
  const sixMonths = new Date(Date.now() + 180 * 86400000).toISOString().slice(0, 10);
  const { data: award, error: awardError } = await owner$.rpc('request_concession_award', { p_enrolment_id: enrolmentId, p_scheme_id: scheme as string, p_value: 50, p_effective_from: monthStart, p_effective_to: sixMonths });
  expect(awardError).toBeNull();
  const { error: decideError } = await owner$.rpc('decide_concession_award', { p_award_id: award as string, p_approve: true });
  expect(decideError).toBeNull();

  const prev = new Date(Date.UTC(new Date().getUTCFullYear(), new Date().getUTCMonth() - 1, 1));
  const summary = { tenant_id: tenant, campus_id: campusId, session_id: session!.id, enrolment_id: enrolmentId, year: prev.getUTCFullYear(), month: prev.getUTCMonth() + 1, working_days: 26, present_days: 23, absent_days: 3, late_count: 0, half_day_count: 0, leave_days: 0 };
  const { error: summaryError } = await db.from('attendance_month_summary').insert({ ...summary, attendance_pct: 89.99, computed_at: new Date().toISOString() });
  expect(summaryError).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/fees/attendance-concessions');
  await page.getByLabel('Minimum attendance %').fill('90');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByLabel('Minimum attendance %')).toHaveValue('90');
  await page.getByTestId('refresh-eligibility').click();
  await expect(page.getByTestId('eligibility-row')).toHaveCount(1);
  await expect(page.getByTestId('eligibility-row')).toContainText('withheld');
  await expect(page.getByTestId('eligibility-row')).toContainText('89.99%');

  await db.from('attendance_month_summary').update({ attendance_pct: 90.2 }).eq('enrolment_id', enrolmentId).eq('year', summary.year).eq('month', summary.month);
  await page.getByTestId('refresh-eligibility').click();
  await expect(page.getByTestId('adjustment-task')).toHaveCount(1);
  await expect(page.getByTestId('adjustment-task')).toContainText('should now be applied');

  await page.getByLabel('Resolution note').fill('Credited on the next challan');
  await page.getByTestId('resolve-adjustment').click();
  await expect(page.getByTestId('adjustment-task')).toHaveCount(0);
});
