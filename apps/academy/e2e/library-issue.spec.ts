import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O04: the librarian looks a student up by card (GR number) and scans books; the limit is enforced and a
// student with unpaid fines over the threshold is blocked, with the outstanding amount shown.

test('a librarian issues books by scan; the loan limit and the fine block are enforced', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, mk } = await seedLibraryTenant('libissue-e2e');
  const librarian = await mk('librarian', 'librarian');

  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const mkStudent = async (name: string) => {
    const { data: s } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: name, p_dob: '2015-03-03', p_gender: 'male' });
    await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: s as string });
    const { data: row } = await db.from('student').select('id, gr_number').eq('id', s as string).single();
    return row!;
  };
  const kid = await mkStudent('Issue Kid');
  const debtor = await mkStudent('Debtor Kid');

  await db.from('library_borrower_policy').insert({ tenant_id: tenant, role: 'student', max_loans: 2, loan_days: 14, max_renewals: 1, fine_per_day: 500, fine_cap: 50000, block_threshold: 30000, effective_from: '2026-01-01' });
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Physics 9' }).select('id').single();
  await db.from('library_copy').insert([1, 2, 3, 4].map((n) => ({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: `ACC-${n}`, barcode: `BC${n}` })));

  // an old returned loan carrying PKR 350 of unpaid fines for the debtor
  const { data: copy4 } = await db.from('library_copy').select('id').eq('tenant_id', tenant).eq('barcode', 'BC4').single();
  const { data: oldLoan } = await db
    .from('library_loan')
    .insert({ tenant_id: tenant, campus_id: campusId, copy_id: copy4!.id, borrower_id: debtor.id, borrower_role: 'student', issued_at: '2026-01-01T05:00:00Z', due_on: '2026-01-15', returned_at: '2026-01-22T05:00:00Z', policy_snapshot: {} })
    .select('id')
    .single();
  await db.from('library_fine').insert({ tenant_id: tenant, campus_id: campusId, loan_id: oldLoan!.id, borrower_id: debtor.id, accrual_date: '2026-01-22', days_overdue: 7, amount: 35000 });

  await signInAs(page, librarian.email);
  await page.goto('/library/circulation');

  await page.getByLabel('Borrower card (GR number) or name').fill(kid.gr_number);
  await page.getByTestId('find-borrower').click();
  await expect(page.getByTestId('selected-borrower')).toContainText('Issue Kid');

  for (const bc of ['BC1', 'BC2']) {
    await page.getByTestId('issue-desk').getByLabel('Book barcode').fill(bc);
    await page.getByTestId('issue-copy').click();
    await expect(page.getByTestId('issue-ok')).toContainText('Physics 9');
  }
  await expect(page.getByTestId('issue-ok')).toContainText('2 of 2 loans in use');
  await expect(page.getByTestId('loan-row')).toHaveCount(2);

  await page.getByTestId('issue-desk').getByLabel('Book barcode').fill('BC3');
  await page.getByTestId('issue-copy').click();
  await expect(page.getByTestId('issue-error')).toContainText('2 of 2');

  // blocked borrower
  await page.getByLabel('Borrower card (GR number) or name').fill(debtor.gr_number);
  await page.getByTestId('find-borrower').click();
  await expect(page.getByTestId('selected-borrower')).toContainText('Unpaid fines PKR 350');
  await page.getByTestId('issue-desk').getByLabel('Book barcode').fill('BC3');
  await page.getByTestId('issue-copy').click();
  await expect(page.getByTestId('issue-error')).toContainText('PKR 350');
});
