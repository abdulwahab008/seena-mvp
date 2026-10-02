import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q06: a tariff and mess rate drive the room and mess ledger lines; the deposit is charged once; the month is explained line by line.

test('hostel charges follow the tariff, mess days and a once-only deposit', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'hfee-e2e');
  expect((await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 2, p_beds_per_room: 4 })).error).toBeNull();
  const { data: stu } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).single();
  const { data: bed } = await db.from('hostel_bed').select('id').eq('tenant_id', tenant).eq('bed_code', 'IQ-101-B1').single();
  expect((await owner$.rpc('allocate_bed', { p_student_id: stu!.id, p_bed_id: bed!.id, p_from: '2026-01-05' })).error).toBeNull();
  expect((await owner$.rpc('record_mess_off', { p_student_id: stu!.id, p_from: '2026-08-10', p_to: '2026-08-14' })).error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/hostel/fees');
  const t = page.getByTestId('tariff-form');
  await t.getByLabel(/Monthly room fee/).fill('8000');
  await t.getByLabel(/Mess rate per day/).fill('350');
  await t.getByLabel(/Security deposit/).fill('20000');
  await t.getByLabel(/Effective from/).fill('2026-01-01');
  await page.getByTestId('tariff-form-submit').click();
  await expect(page.getByTestId('tariff-row')).toHaveCount(1);

  await page.getByTestId('post-hostel-form').getByLabel(/Any day/).fill('2026-08-15');
  await page.getByTestId('post-hostel-form-submit').click();
  await expect(page.getByTestId('deposit-row')).toHaveCount(1);

  const { data: lines } = await db.from('fee_ledger').select('amount_paisa, fee_head:fee_head_id(code)').eq('tenant_id', tenant).eq('value_date', '2026-08-01');
  const byHead = Object.fromEntries((lines ?? []).map((l) => [(l.fee_head as unknown as { code: string }).code, l.amount_paisa]));
  expect(byHead).toMatchObject({ HOSTEL_ROOM: 800000, HOSTEL_MESS: 910000 });

  await page.goto(`/hostel/fees?gr=${stu!.gr_number}&month=2026-08-15`);
  await expect(page.getByTestId('explain-mess')).toContainText('26 billable days');
});
