import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-G16: the weekly evaluation raises a level-1 warning below the threshold; a teacher closes it with a reason.

test('a student below the minimum gets a warning that can be closed with a reason', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(1, 'short-e2e');
  const enrolmentId = challans[0]!.enrolment_id;
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: enrol } = await db.from('enrolment').select('section_id').eq('id', enrolmentId).single();
  const today = Date.now();
  await db.from('academic_session').update({ starts_on: new Date(today - 100 * 86400000).toISOString().slice(0, 10), ends_on: new Date(today + 200 * 86400000).toISOString().slice(0, 10), status: 'active' }).eq('id', session!.id);
  const { error: policyError } = await owner$.rpc('set_attendance_policy', { p_campus_id: campusId, p_session_id: session!.id, p_min_attendance_pct: 75 });
  expect(policyError).toBeNull();

  const rows = Array.from({ length: 35 }, (_, i) => ({
    tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: enrol!.section_id, enrolment_id: enrolmentId,
    attendance_date: new Date(today - (i + 1) * 86400000).toISOString().slice(0, 10), status: i < 25 ? 'present' : 'absent', source: 'web',
  }));
  const { error: insertError } = await db.from('attendance_day').insert(rows);
  expect(insertError).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/attendance/shortage');
  await page.getByTestId('run-shortage-eval').click();
  await expect(page.getByTestId('shortage-row')).toHaveCount(1);
  await expect(page.getByTestId('shortage-row')).toContainText('71.43%');
  await expect(page.getByTestId('shortage-row')).toContainText('Level 1');

  await page.getByTestId('run-shortage-eval').click();
  await expect(page.getByTestId('shortage-row')).toContainText('Level 1');

  await page.getByLabel('Reason for closing').fill('short');
  await page.getByTestId('close-shortage').click();
  await expect(page.getByText('Give a reason of at least 10 characters')).toBeVisible();
  await page.getByLabel('Reason for closing').fill('Condoned on medical grounds');
  await page.getByTestId('close-shortage').click();
  await expect(page.getByTestId('shortage-row')).toHaveCount(0);
});
