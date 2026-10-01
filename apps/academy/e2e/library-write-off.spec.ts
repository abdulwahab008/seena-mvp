import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O08: declaring a lost book posts one LIB_RECOVERY charge (cost x 1.5 + accrued fine) to the student's fee ledger;
// finding it again reverses by credit note and keeps both rows.

const karachiDate = (offsetDays: number) => new Date(Date.now() + offsetDays * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

test('a lost book is written off onto the fee ledger and later reversed by credit note', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, mk } = await seedLibraryTenant('libwo-e2e');
  const librarian = await mk('librarian', 'librarian');

  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: s } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: 'Careless Kid', p_dob: '2015-03-03', p_gender: 'male' });
  const { data: enrolment } = await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: s as string });

  const snapshot = { fine_per_day: 500, fine_cap: null, loan_days: 14, max_loans: 2, max_renewals: 1, role: 'student' };
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Lost Chemistry' }).select('id').single();
  const { data: copy } = await db
    .from('library_copy')
    .insert({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: 'LIB-2024-00099', barcode: 'LOST1', status: 'issued', purchase_cost: 85000 })
    .select('id')
    .single();
  await db.from('library_loan').insert({ tenant_id: tenant, campus_id: campusId, copy_id: copy!.id, borrower_id: s as string, borrower_role: 'student', issued_at: new Date(Date.now() - 40 * 86_400_000).toISOString(), due_on: karachiDate(-24), policy_snapshot: snapshot });
  expect((await db.rpc('accrue_library_fines', { p_date: karachiDate(0) })).error).toBeNull();

  await signInAs(page, librarian.email);
  await page.goto('/library/write-offs');
  await page.getByLabel('Barcode of the lost copy').fill('LOST1');
  await page.getByTestId('write-off').click();
  await expect(page.getByTestId('write-off-ok')).toContainText('PKR 1,395');
  await expect(page.getByTestId('write-off-ok')).toContainText('LIB_RECOVERY');

  const { data: charge } = await db.from('fee_ledger').select('amount_paisa, direction, entry_type').eq('tenant_id', tenant).eq('enrolment_id', enrolment as string).eq('source_type', 'library_write_off');
  expect(charge).toHaveLength(1);
  expect(charge![0]).toMatchObject({ amount_paisa: 139500, direction: 'debit', entry_type: 'charge' });
  await expect(page.getByTestId('write-off-row')).toHaveCount(1);
  await expect(page.getByTestId('write-off-row')).toContainText('PKR 1,395');

  // the book turns up: reversed by credit note, both rows stay visible
  await page.getByLabel('Reason for reversal').fill('Found in the lab');
  await page.getByTestId('reverse-write-off').click();
  await expect(page.getByTestId('write-off-row')).toHaveCount(2);
  await expect(page.getByTestId('write-off-table')).toContainText('Reversal (credit note)');

  const { data: ledger } = await db.from('fee_ledger').select('direction, entry_type').eq('tenant_id', tenant).eq('enrolment_id', enrolment as string);
  expect(ledger!.map((l) => `${l.entry_type}:${l.direction}`).sort()).toEqual(['charge:debit', 'reversal:credit']);
  const { data: c } = await db.from('library_copy').select('status').eq('id', copy!.id).single();
  expect(c!.status).toBe('available');

  // the accession number stays taken
  await page.goto('/library/copies?title=' + title!.id);
  await expect(page.getByTestId('copy-row')).toContainText('LIB-2024-00099');
});
