import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q03: a pass is issued against a guardian CNIC, a second open pass is refused, an unknown collector needs a Principal override, and the printed pass carries a QR.

test('gate pass: guardian match, one open pass, override for an unknown collector, printable QR', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'pass-e2e');
  const block = await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 2, p_beds_per_room: 4 });
  expect(block.error).toBeNull();
  const { data: stu } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).single();
  const { data: bed } = await db.from('hostel_bed').select('id').eq('tenant_id', tenant).eq('bed_code', 'IQ-101-B1').single();
  const alloc = await owner$.rpc('allocate_bed', { p_student_id: stu!.id, p_bed_id: bed!.id, p_from: '2026-01-05' });
  expect(alloc.error).toBeNull();
  const { data: g } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Father One', cnic: '35202-1234567-1' }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: stu!.id, guardian_id: g!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/hostel/gate-passes');
  const form = page.getByTestId('pass-form');
  await form.getByLabel(/GR number/).fill(stu!.gr_number);
  await form.getByLabel(/Purpose/).fill('Weekend at home');
  await form.getByLabel(/Leaves at/).fill('2026-08-14T16:00');
  await form.getByLabel(/Due back at/).fill('2026-08-16T20:00');
  await form.getByLabel(/Collected by/).fill('Father One');
  await form.getByLabel(/Collector CNIC/).fill('35202-1234567-1');
  await page.getByTestId('pass-form-submit').click();
  await expect(page.getByTestId('pass-row')).toHaveCount(1);

  // A second pass while one is out.
  await form.getByLabel(/GR number/).fill(stu!.gr_number);
  await form.getByLabel(/Purpose/).fill('Another trip');
  await form.getByLabel(/Leaves at/).fill('2026-08-15T10:00');
  await form.getByLabel(/Due back at/).fill('2026-08-15T18:00');
  await form.getByLabel(/Collected by/).fill('Father One');
  await form.getByLabel(/Collector CNIC/).fill('35202-1234567-1');
  await page.getByTestId('pass-form-submit').click();
  await expect(page.getByTestId('pass-form-error')).toContainText('PASS_ALREADY_OPEN');

  // Return it, then an unknown collector needs the override reason.
  await page.getByTestId('return-GP-2026-00001').click();
  await expect(page.getByTestId('pass-row')).toContainText('returned');
  await form.getByLabel(/GR number/).fill(stu!.gr_number);
  await form.getByLabel(/Purpose/).fill('Visit');
  await form.getByLabel(/Leaves at/).fill('2026-09-20T16:00');
  await form.getByLabel(/Due back at/).fill('2026-09-20T20:00');
  await form.getByLabel(/Collected by/).fill('Uncle Unknown');
  await form.getByLabel(/Collector CNIC/).fill('35202-7654321-9');
  await page.getByTestId('pass-form-submit').click();
  await expect(page.getByTestId('pass-form-error')).toContainText('reason');
  await form.getByLabel(/Principal override reason/).fill('Father phoned the Principal; uncle collecting');
  await page.getByTestId('pass-form-submit').click();
  await expect(page.getByTestId('pass-row')).toHaveCount(2);

  // The printable pass.
  await page.getByRole('link', { name: 'GP-2026-00002' }).click();
  await expect(page.getByTestId('pass-serial')).toHaveText('GP-2026-00002');
  await expect(page.getByTestId('pass-gr')).toHaveText(stu!.gr_number);
  await expect(page.getByTestId('pass-qr').locator('svg')).toBeVisible();
  await expect(page.getByTestId('pass-photo-box')).toBeVisible();
});
