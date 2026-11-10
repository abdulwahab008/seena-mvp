import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('hostel reports show occupancy and a resident who owes fees', async ({ page }) => {
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'hostel-reports-e2e');
  expect((await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 2, p_beds_per_room: 2 })).error).toBeNull();
  const { data: student } = await db.from('student').select('id, name_en').eq('tenant_id', tenant).single();
  const { data: bed } = await db.from('hostel_bed').select('id').eq('bed_code', 'IQ-101-B1').eq('tenant_id', tenant).single();
  const start = new Date(Date.now() - 2 * 86_400_000).toISOString().slice(0, 10);
  expect((await owner$.rpc('allocate_bed', { p_student_id: student!.id, p_bed_id: bed!.id, p_from: start })).error).toBeNull();

  await signInAs(page, email);
  await page.goto('/hostel/reports');
  await expect(page.getByTestId('occupancy-row').locator('td')).toHaveText(['Iqbal Block', '4', '1', '3', '25%']);
  await page.getByLabel('Only residents who owe').check();
  await page.getByRole('main').getByRole('button', { name: 'Show' }).click();
  await expect(page).toHaveURL(/owing=1/);
  await expect(page.getByTestId('resident-row')).toContainText(student!.name_en);
  await expect(page.getByTestId('resident-row')).toContainText('IQ-101-B1');
});

test('asset reports total book value by category', async ({ page }) => {
  const { owner$, email, campusId } = await seedFeesTenant(1, 'asset-reports-e2e');
  for (const [tag, cost] of [['DESK-1', 2000000], ['DESK-2', 3000000]] as const) {
    const r = await owner$.rpc('create_asset', { p_campus_id: campusId, p_tag_no: tag, p_name: 'Teacher desk', p_category: 'furniture', p_purchased_on: '2026-08-01', p_capitalised_cost: cost, p_useful_life_months: 60, p_salvage_value: 0, p_method: 'SL' });
    expect(r.error).toBeNull();
  }

  await signInAs(page, email);
  await page.goto('/assets/reports');
  await expect(page.getByRole('region', { name: 'Assets by status' })).toContainText('In use2');
  await expect(page.getByTestId('asset-category-row').locator('td')).toHaveText(['Furniture', '2', 'PKR 50,000', 'PKR 0', 'PKR 50,000']);
});
