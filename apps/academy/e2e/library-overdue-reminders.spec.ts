import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('the library reminds parents of overdue books from the circulation desk', async ({ page }) => {
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(1, 'lib-overdue');
  const { data: enrol } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const { data: mum } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Mother', phone_e164: '+923008880001' }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrol!.student_id, guardian_id: mum!.id, relationship: 'mother', is_primary: true, receives_billing: true, receives_academic: true });
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Physics 9' }).select('id').single();
  const { data: copy } = await db.from('library_copy').insert({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: 'ACC-1', barcode: `BC-${tenant.slice(0, 8)}` }).select('id').single();
  const due = new Date(Date.now() - 5 * 86400000).toISOString().slice(0, 10);
  const loan = await db.from('library_loan').insert({ tenant_id: tenant, campus_id: campusId, copy_id: copy!.id, borrower_id: enrol!.student_id, borrower_role: 'student', due_on: due, policy_snapshot: {} });
  expect(loan.error).toBeNull();

  await signInAs(page, email);
  await page.goto('/library/circulation');
  await expect(page.getByTestId('loan-row')).toContainText('Overdue');
  await page.getByRole('button', { name: 'Remind parents of overdue books' }).click();
  await expect(page.getByText('Sent 1 overdue reminder to parents.')).toBeVisible();
});
