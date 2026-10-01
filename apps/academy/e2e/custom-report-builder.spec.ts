import { createClient } from '@supabase/supabase-js';
import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S07: build, preview, save and reopen a report; column permissions hold for a role that
// may not see guardian CNIC.

test('an owner builds, previews and saves a report; an accountant cannot use guardian CNIC', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId } = await seedFeesTenant(4, 'builder-e2e');

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/reports/builder');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('column-picker')).toContainText('Guardian CNIC');
  await page.getByLabel('Report name').fill('Class 1 roster');
  await page.getByTestId('column-picker').getByLabel('GR number').check();
  await page.getByTestId('column-picker').getByLabel('Student name').check();
  await page.getByTestId('add-filter').click();
  await page.getByLabel('Filter column').selectOption('class_code');
  await page.getByLabel('Filter value').fill('1');
  await page.getByTestId('preview').click();
  await expect(page.getByTestId('report-row')).toHaveCount(4);
  await expect(page.getByTestId('preview-result')).toContainText('Showing 4 of 4 rows');

  await page.getByTestId('save-report').click();
  await expect(page).toHaveURL(/\/reports\/builder\/[0-9a-f-]{36}$/);
  await expect(page.getByTestId('run-summary')).toContainText('4 of 4 rows');
  await expect(page.getByTestId('report-row')).toHaveCount(4);

  // An accountant: guardian CNIC is not in their picker and a hand-edited definition is refused.
  const accEmail = `acc-${tenant.slice(0, 8)}@builder-e2e.test`;
  const { data: acc } = await db.auth.admin.createUser({ email: accEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: acc.user!.id, tenant_id: tenant, app_role: 'accountant', full_name: 'Builder Accountant' });
  await db.from('user_campus').insert({ user_id: acc.user!.id, tenant_id: tenant, campus_id: campusId });
  const acc$ = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321', process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  await acc$.auth.signInWithPassword({ email: accEmail, password: SEED_PASSWORD });
  const { data: cols } = await acc$.rpc('fn_report_columns', { p_dataset_key: 'ds_student_enrolment' });
  expect((cols ?? []).map((c: { key: string }) => c.key)).not.toContain('guardian_cnic');
  const sneaky = await acc$.rpc('save_report', { p_name: 'x', p_dataset_key: 'ds_student_enrolment', p_definition: { columns: ['gr_number', 'guardian_cnic'] }, p_is_shared: false });
  expect(sneaky.error?.message).toContain('column_not_permitted');
});
