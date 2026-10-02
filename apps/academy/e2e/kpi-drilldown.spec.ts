import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S04: click a dashboard number, see the rows behind it, get a reconciliation
// notice when the aggregate is stale, and export with the same filters.

test('the owner drills from the outstanding KPI to the challan rows, sees the stale-aggregate notice and exports', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(3, 'drill-e2e');

  // Real aggregates, then one made stale: as if a back-dated receipt arrived after the refresh.
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const refreshed = await db.rpc('refresh_agg_campus_day', { p_from: today, p_to: today, p_tenant_id: tenant });
  expect(refreshed.error).toBeNull();
  const { error: staleError } = await db
    .from('agg_campus_day')
    .update({ outstanding_paisa: 3_000_000, outstanding_0_30_paisa: 3_000_000, outstanding_31_60_paisa: 0, outstanding_60plus_paisa: 0 })
    .eq('campus_id', campusId)
    .eq('day', today);
  expect(staleError).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/dashboard/owner');
  await page.getByTestId('drill-outstanding').first().click();
  await expect(page).toHaveURL(/\/dashboard\/drilldown\/outstanding/);

  await expect(page.getByTestId('drilldown-row')).toHaveCount(3);
  // Every row carries the real challan number (11 digits + check digit) of a seeded challan.
  expect(challans).toHaveLength(3);
  const listed = await page.getByTestId('drilldown-row').evaluateAll((rows) => rows.map((r) => r.querySelector('td')?.textContent ?? ''));
  expect([...listed].sort()).toEqual(challans.map((c) => c.challan_no as string).sort());
  await expect(page.getByTestId('drilldown-summary')).toContainText('3 rows');
  await expect(page.getByTestId('drilldown-summary')).toContainText('25,500.00');

  // 25,500 live vs 30,000 in the aggregate: well beyond 0.5%.
  await expect(page.getByTestId('reconciliation-notice')).toContainText('Dashboard (aggregate)');
  await expect(page.getByTestId('reconciliation-notice')).toContainText('last refreshed');

  await page.getByTestId('export-drilldown').click();
  await expect.poll(async () => (await db.from('report_export_job').select('params, dataset_key').eq('tenant_id', tenant)).data?.length).toBe(1);
  const { data: job } = await db.from('report_export_job').select('params, dataset_key').eq('tenant_id', tenant).single();
  expect(job!.dataset_key).toBe('drilldown_outstanding');
  expect(job!.params).toMatchObject({ campus_id: campusId });
});
