import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S10: month-of-session alignment, "no data" instead of -100%, absolute and percentage change.

test('the owner compares two sessions by month-of-session and sees no-data months excluded', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId } = await seedFeesTenant(0, 'yoy-e2e');

  const mk = async (name: string, starts: string, ends: string) => {
    const { data, error } = await db.from('academic_session').insert({ tenant_id: tenant, name, starts_on: starts, ends_on: ends, status: 'closed', is_current: false }).select('id').single();
    expect(error).toBeNull();
    return data!.id as string;
  };
  const prior = await mk('2020-21', '2020-04-01', '2021-03-31');
  const current = await mk('2021-22', '2021-04-01', '2022-03-31');

  // The seeded campus was provisioned just now; the series ignores months before a campus
  // existed (a range refresh writes zero rows for them), so it must predate both sessions.
  const { error: campusError } = await db.from('campus').update({ created_at: '2020-01-01T00:00:00Z' }).eq('id', campusId);
  expect(campusError).toBeNull();

  // Prior session has data only from October (index 7); this one has the whole year.
  const rows: Record<string, unknown>[] = [];
  for (let i = 1; i <= 12; i++) {
    const d = (y: number, m: number) => new Date(Date.UTC(y, m, 15)).toISOString().slice(0, 10);
    if (i >= 7) rows.push({ tenant_id: tenant, campus_id: campusId, day: d(2020, 3 + i - 1), enrolled_count: 100, present_count: 90, marked_sections: 1, collected_paisa: 100000, billed_paisa: 200000 });
    rows.push({ tenant_id: tenant, campus_id: campusId, day: d(2021, 3 + i - 1), enrolled_count: 110, present_count: 99, marked_sections: 1, collected_paisa: 120000, billed_paisa: 200000 });
  }
  const { error } = await db.from('agg_campus_day').insert(rows as never);
  expect(error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // The seeded school already has its own (newer) session, which the page would pick by default.
  await page.goto(`/reports/year-on-year?current=${current}&prior=${prior}`);
  await expect(page.getByTestId('yoy-row')).toHaveCount(12);
  const first = page.getByTestId('yoy-row').first();
  await expect(first).toContainText('Apr 2021');
  await expect(first).toContainText('Apr 2020');
  await expect(first).toHaveAttribute('data-status', 'no_data');
  await expect(first.getByTestId('yoy-pct')).toContainText('no data');
  await expect(first.getByTestId('yoy-pct')).not.toContainText('-100');

  const seventh = page.getByTestId('yoy-row').nth(6);
  await expect(seventh).toHaveAttribute('data-status', 'ok');
  await expect(seventh.getByTestId('yoy-pct')).toContainText('+20.0%');
  await expect(seventh.getByTestId('yoy-abs')).toContainText('+200.00');
  await expect(page.getByTestId('yoy-overall')).toContainText('6 months were left out');
});
