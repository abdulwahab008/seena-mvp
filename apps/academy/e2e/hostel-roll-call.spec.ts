import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the warden takes night roll call of hostel residents', async ({ page }) => {
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'roll-call-e2e');
  const block = await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 2, p_beds_per_room: 2 });
  expect(block.error).toBeNull();
  const { data: students } = await db.from('student').select('id, name_en').eq('tenant_id', tenant);
  const { data: bed } = await db.from('hostel_bed').select('id').eq('bed_code', 'IQ-101-B1').eq('tenant_id', tenant).single();
  const start = new Date(Date.now() - 2 * 86_400_000).toISOString().slice(0, 10);
  const alloc = await owner$.rpc('allocate_bed', { p_student_id: students![0]!.id, p_bed_id: bed!.id, p_from: start });
  expect(alloc.error).toBeNull();

  await signInAs(page, email);
  await page.goto('/hostel/roll-call');
  await page.waitForLoadState('networkidle');
  const row = page.getByTestId('roll-call-row').filter({ hasText: students![0]!.name_en });
  await expect(row).toContainText('IQ-101-B1');
  await row.getByLabel('Absent').check();
  await page.getByRole('button', { name: 'Save roll call' }).click();
  await expect(page.getByText('Roll call saved for 1 residents.')).toBeVisible();
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Absent1');
});
