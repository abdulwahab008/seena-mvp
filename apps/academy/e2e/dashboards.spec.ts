import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S02 / FR-S03: the owner KPI table and the principal's live Today screen.

test('owner KPIs come from the aggregates; Today is live and excludes unconfirmed money', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(2, 'dash-e2e');
  const [c1, c2] = challans;

  const today = new Date(Date.now() + 5 * 3600_000).toISOString().slice(0, 10);
  // Karachi "today" without importing the DB helper: UTC+5.
  const { error: payErr } = await owner$.rpc('record_payment', { p_enrolment_id: c1!.enrolment_id, p_amount_paisa: 850000, p_mode: 'cash', p_value_date: today });
  expect(payErr).toBeNull();
  await db.from('payment_intent').insert({
    tenant_id: tenant, campus_id: campusId, enrolment_id: c2!.enrolment_id, challan_id: c2!.id, gateway: 'jazzcash',
    gateway_ref: `JA-${Date.now()}`, amount_paisa: 850000, expires_at: new Date(Date.now() + 20 * 60_000).toISOString(), status: 'pending',
  });
  const { data: section } = await db.from('class_section').select('id, session_id').eq('campus_id', campusId).single();
  await db.from('attendance_day').insert([
    { tenant_id: tenant, campus_id: campusId, session_id: section!.session_id, section_id: section!.id, enrolment_id: c1!.enrolment_id, attendance_date: today, status: 'present' },
    { tenant_id: tenant, campus_id: campusId, session_id: section!.session_id, section_id: section!.id, enrolment_id: c2!.enrolment_id, attendance_date: today, status: 'absent' },
  ]);

  const from = new Date(Date.now() - 2 * 86400_000).toISOString().slice(0, 10);
  const { error: refreshErr } = await db.rpc('refresh_agg_campus_day', { p_from: from, p_to: today, p_tenant_id: tenant });
  expect(refreshErr).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/dashboard/owner');
  const row = page.getByTestId('owner-kpi-row').first();
  await expect(row).toContainText('PKR 8,500');
  await expect(page.getByTestId('metric-definitions')).toContainText('Fees COLLECTED');
  await expect(page.getByTestId('stale-banner')).toHaveCount(0);

  await page.goto('/dashboard/today');
  await expect(page.getByTestId('sections-marked')).toHaveText('1/1 sections marked');
  await expect(page.getByTestId('absent-count')).toHaveText('1');
  await expect(page.getByTestId('collected-today')).toHaveText('PKR 8,500');
  await expect(page.getByTestId('pending-online')).toContainText('1 online payment');
  await expect(page.getByTestId('absentee-row')).toHaveCount(1);
});
