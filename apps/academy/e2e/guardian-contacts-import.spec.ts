import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test('an owner links fathers to existing students from a CSV and siblings share one guardian', async ({ page }) => {
  const { admin, tenantId, campusId, email, password } = await seedSchoolOwner('guardian-import');
  const { error } = await admin.from('student').insert([
    { tenant_id: tenantId, campus_id: campusId, gr_number: 'GE-1', name_en: 'Elder Child', father_name_en: 'Tariq Mehmood', dob: '2012-01-01', gender: 'male' },
    { tenant_id: tenantId, campus_id: campusId, gr_number: 'GE-2', name_en: 'Younger Child', father_name_en: 'Tariq Mehmood', dob: '2015-01-01', gender: 'female' },
  ]);
  if (error) throw error;

  await page.goto('/login?redirectTo=%2Fstudents%2Fimport');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/students\/import$/);
  await page.waitForLoadState('networkidle');

  const csv = 'gr_number,father_cnic,father_phone\nGE-1,35202-1234567-1,0300 1234567\nGE-2,3520212345671,\nNOPE,35202-1111111-1,\n';
  await page.getByLabel('Guardian file (.csv)').setInputFiles({ name: 'fathers.csv', mimeType: 'text/csv', buffer: Buffer.from(csv) });
  await page.getByTestId('guardian-import-submit').click();

  await expect(page.getByTestId('guardian-import-result')).toContainText('2 linked · 1 not linked');
  await expect(page.getByTestId('guardian-import-result')).toContainText('Row 4 (GR NOPE): No student has this GR number.');

  const { data: links } = await admin
    .from('student_guardian')
    .select('guardian_id, is_primary, receives_billing, student:student!inner(gr_number)')
    .eq('tenant_id', tenantId);
  expect(links).toHaveLength(2);
  expect(new Set(links!.map((l) => l.guardian_id)).size).toBe(1);
  expect(links!.every((l) => l.is_primary && l.receives_billing)).toBe(true);
});
