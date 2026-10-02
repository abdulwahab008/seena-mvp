import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P01: a route with ordered stops, slab-driven fares and a printable sheet showing pickup and drop times.

test('the transport office builds a route, re-orders a stop and prints the sheet with times', async ({ page }) => {
  test.setTimeout(120000);
  const { email, tenant, db } = await seedFeesTenant(0, 'route-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transport/routes');
  await page.getByTestId('slab-form').getByLabel(/Slab code/).fill('ZONE-B');
  await page.getByTestId('slab-form').getByLabel(/Slab name/).fill('Zone B');
  await page.getByTestId('slab-form').getByLabel(/Monthly fare/).fill('3500');
  await page.getByTestId('slab-form').getByLabel(/Effective from/).fill('2026-01-01');
  await page.getByTestId('slab-form-submit').click();
  await expect(page.getByTestId('slab-row')).toHaveCount(1);

  // A fuel-driven revision is a new dated version of the same slab, not a per-student edit.
  await page.getByTestId('slab-form').getByLabel(/Slab code/).fill('ZONE-B');
  await page.getByTestId('slab-form').getByLabel(/Slab name/).fill('Zone B');
  await page.getByTestId('slab-form').getByLabel(/Monthly fare/).fill('3900');
  await page.getByTestId('slab-form').getByLabel(/Effective from/).fill('2026-09-01');
  await page.getByTestId('slab-form-submit').click();
  await expect(page.getByTestId('slab-row')).toHaveCount(2);

  await page.getByTestId('route-form').getByLabel(/Route code/).fill('R-04');
  await page.getByTestId('route-form').getByLabel(/Route name/).fill('Johar Town Morning');
  await page.getByTestId('route-form').getByLabel(/Shift/).selectOption('morning');
  await page.getByTestId('route-form-submit').click();
  await expect(page.getByTestId('route-row')).toHaveCount(1);
  await page.getByTestId('route-row').getByRole('link').click();

  const names = ['Gate One', 'Market', 'Bridge'];
  const times = ['06:45', '06:55', '07:05'];
  for (const [i, name] of names.entries()) {
    const form = page.getByTestId('stop-form');
    // The label reads "Stop name *" (required marker); "Stop name (Urdu)" is the other field.
    await form.getByLabel(/^Stop name( \*)?$/).fill(name);
    await form.getByLabel(/Pickup time/).fill(times[i]!);
    await form.getByLabel(/Drop time/).fill('14:10');
    await form.getByLabel(/Fare slab/).selectOption({ index: 1 });
    await page.getByTestId('stop-form-submit').click();
    await expect(page.getByTestId('stop-row')).toHaveCount(i + 1);
  }

  // Move the third stop to the front: one renumbering, no duplicate sequence.
  await page.getByLabel('Position for stop 3').fill('1');
  await page.getByTestId('stop-move-3').click();
  await expect(page.getByTestId('stop-row').first()).toContainText('Bridge');
  await expect(page.getByTestId('stop-seq')).toHaveText(['1', '2', '3']);

  const { data: stops } = await db.from('transport_stop').select('seq').eq('tenant_id', tenant);
  expect((stops ?? []).map((s) => s.seq).sort()).toEqual([1, 2, 3]);

  await page.getByTestId('route-sheet-link').click();
  await expect(page.getByTestId('route-sheet')).toBeVisible();
  await expect(page.getByTestId('sheet-row')).toHaveCount(3);
  await expect(page.getByTestId('sheet-pickup').first()).toHaveText('07:05');
  await expect(page.getByTestId('sheet-drop').first()).toHaveText('14:10');
});
