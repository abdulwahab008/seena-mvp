import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';
import { todayPk } from './support/today';

test('library reports list circulation, overdue loans with days late, and fines by borrower', async ({ page }) => {
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(1, 'lib-reports-e2e');
  const { data: enrol } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const { data: student } = await db.from('student').select('name_en').eq('id', enrol!.student_id).single();
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Chemistry 10' }).select('id').single();
  const { data: copy } = await db.from('library_copy').insert({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: 'ACC-77', barcode: `BC77-${tenant.slice(0, 8)}` }).select('id').single();
  const due = new Date(Date.parse(`${todayPk()}T00:00:00Z`) - 4 * 86400000).toISOString().slice(0, 10);
  const { data: loan, error } = await db
    .from('library_loan')
    .insert({ tenant_id: tenant, campus_id: campusId, copy_id: copy!.id, borrower_id: enrol!.student_id, borrower_role: 'student', due_on: due, policy_snapshot: {} })
    .select('id')
    .single();
  expect(error).toBeNull();
  const { error: ferr } = await db.from('library_fine').insert({ tenant_id: tenant, campus_id: campusId, loan_id: loan!.id, borrower_id: enrol!.student_id, accrual_date: due, days_overdue: 4, amount: 4000 });
  expect(ferr).toBeNull();

  await signInAs(page, email);
  await page.goto('/library/reports');
  await expect(page.getByTestId('circulation-row')).toContainText('Chemistry 10');
  await expect(page.getByTestId('circulation-row')).toContainText('Overdue');

  await page.goto('/library/reports?report=overdue');
  await expect(page.getByTestId('overdue-row')).toContainText(student!.name_en);
  await expect(page.getByTestId('overdue-row').locator('td').nth(4)).toHaveText('4');

  await page.goto('/library/reports?report=fines');
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('OutstandingPKR 40');
});
