import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q02: a bed holds one student; a second request is refused; a transfer moves the stay in one step.

test('allocating the same bed twice is refused and a transfer moves the stay', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(2, 'bed-e2e');
  const block = await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 20, p_beds_per_room: 4 });
  expect(block.error).toBeNull();
  const { data: students } = await db.from('student').select('gr_number').eq('tenant_id', tenant).order('gr_number');
  expect(students).toHaveLength(2);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/hostel/allocations');
  const form = page.getByTestId('bed-form');
  await form.getByLabel(/GR number/).fill(students![0]!.gr_number);
  await form.getByLabel(/Bed code/).fill('IQ-105-B3');
  await form.getByLabel(/Starts on/).fill('2026-08-01');
  await page.getByTestId('bed-form-submit').click();
  await expect(page.getByTestId('stay-row')).toHaveCount(1);

  await form.getByLabel(/GR number/).fill(students![1]!.gr_number);
  await form.getByLabel(/Bed code/).fill('IQ-105-B3');
  await form.getByLabel(/Starts on/).fill('2026-09-01');
  await page.getByTestId('bed-form-submit').click();
  await expect(page.getByTestId('bed-form-error')).toContainText('BED_TAKEN');

  const transfer = page.getByTestId('transfer-form');
  await transfer.getByLabel(/GR number/).fill(students![0]!.gr_number);
  await transfer.getByLabel(/New bed code/).fill('IQ-210-B1');
  await transfer.getByLabel(/Moves on/).fill('2026-10-05');
  await page.getByTestId('transfer-form-submit').click();
  await expect(page.getByTestId('stay-row')).toHaveCount(2);

  const { data: stays } = await db.from('hostel_allocation').select('starts_on, ends_on').eq('tenant_id', tenant).order('starts_on');
  expect(stays).toEqual([
    { starts_on: '2026-08-01', ends_on: '2026-10-04' },
    { starts_on: '2026-10-05', ends_on: null },
  ]);
});
