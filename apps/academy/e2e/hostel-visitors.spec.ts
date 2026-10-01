import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q04: the gate logs visitors in and out; a guardian CNIC is recognised; the register lists who is inside, newest first.

test('the gate logs a verified guardian and an unverified visitor and signs one out', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(1, 'visit-e2e');
  const { data: stu } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).single();
  const { data: g } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Father One', cnic: '35202-1234567-1' }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: stu!.id, guardian_id: g!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/hostel/visitors');
  const form = page.getByTestId('visitor-form');
  await form.getByLabel(/Student GR number/).fill(stu!.gr_number);
  await form.getByLabel(/Student GR number/).blur();
  await expect(page.getByTestId('visited-student')).toBeVisible();
  await form.getByLabel(/Visitor name/).fill('Father One');
  await form.getByLabel(/Visitor CNIC/).fill('35202-1234567-1');
  await form.getByLabel(/Visitor CNIC/).blur();
  await expect(page.getByTestId('cnic-match')).toContainText('father');
  await page.getByTestId('visitor-form-submit').click();
  await expect(page.getByTestId('open-visit-row')).toHaveCount(1);
  await expect(page.getByTestId('open-visit-row')).toContainText('verified');

  await form.getByLabel(/Student GR number/).fill(stu!.gr_number);
  await form.getByLabel(/Student GR number/).blur();
  await expect(page.getByTestId('visited-student')).toBeVisible();
  await form.getByLabel(/Visitor name/).fill('Family Friend');
  await form.getByLabel(/Visitor CNIC/).fill('35202-7654321-9');
  await form.getByLabel(/Relationship/).fill('family friend');
  await page.getByTestId('visitor-form-submit').click();
  await expect(page.getByTestId('open-visit-row')).toHaveCount(2);
  await expect(page.getByTestId('open-visit-row').first()).toContainText('Family Friend');
  await expect(page.getByTestId('open-visit-row').first()).toContainText('unverified');

  await page.getByTestId('signout-Father One').click();
  await expect(page.getByTestId('open-visit-row')).toHaveCount(1);
});
