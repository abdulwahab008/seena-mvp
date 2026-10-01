import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O06: students queue for a title whose only copy is out; a duplicate is refused; when the copy is returned it is
// held for the head of the queue (a walk-in cannot take it).

test('reservations queue first-come-first-served and the returned copy is held for the head of the queue', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, tenant, campusId, mk } = await seedLibraryTenant('libres-e2e');
  const librarian = await mk('librarian', 'librarian');

  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const mkStudent = async (name: string) => {
    const { data: s } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: name, p_dob: '2015-03-03', p_gender: 'male' });
    await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: s as string });
    const { data: row } = await db.from('student').select('id, gr_number').eq('id', s as string).single();
    return row!;
  };
  const a = await mkStudent('Queue Kid A');
  const b = await mkStudent('Queue Kid B');
  const walkin = await mkStudent('Walkin Kid');
  const holder = await mkStudent('Holder Kid');

  await db.from('library_borrower_policy').insert({ tenant_id: tenant, role: 'student', max_loans: 2, loan_days: 14, max_renewals: 1, fine_per_day: 500, effective_from: '2026-01-01' });
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Rare Physics Reader' }).select('id').single();
  const { data: copy } = await db
    .from('library_copy')
    .insert({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: 'ACC-1', barcode: 'RARE1', status: 'issued' })
    .select('id')
    .single();
  const due = new Date(Date.now() + 5 * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  await db.from('library_loan').insert({ tenant_id: tenant, campus_id: campusId, copy_id: copy!.id, borrower_id: holder.id, borrower_role: 'student', due_on: due, policy_snapshot: { fine_per_day: 0, max_renewals: 1, loan_days: 14 } });

  await signInAs(page, librarian.email);
  await page.goto('/library/reservations');

  const reserveFor = async (gr: string) => {
    const form = page.getByTestId('reserve-for-borrower');
    await form.getByLabel('Title').fill('Rare Physics');
    await form.getByRole('button', { name: 'Search' }).click();
    await form.getByRole('button', { name: 'Rare Physics Reader' }).click();
    await form.getByLabel('Borrower (GR number or name)').fill(gr);
    await form.getByRole('button', { name: 'Find', exact: true }).click();
    await expect(page.getByTestId('chosen-borrower')).toBeVisible();
    await page.getByTestId('reserve-submit').click();
  };

  await reserveFor(a.gr_number);
  await expect(page.getByTestId('reserve-message')).toContainText('Queue position 1');
  await page.goto('/library/reservations');
  await reserveFor(b.gr_number);
  await expect(page.getByTestId('reserve-message')).toContainText('Queue position 2');
  await page.goto('/library/reservations');
  await reserveFor(a.gr_number);
  await expect(page.getByTestId('reserve-message')).toContainText('already have an active reservation');

  // the holder returns the book: A is next
  await page.goto('/library/circulation');
  await page.getByTestId('return-desk').getByLabel('Book barcode').fill('RARE1');
  await page.getByTestId('return-copy').click();
  await expect(page.getByTestId('return-ok')).toContainText('Held at the counter for the next reader');

  // a walk-in cannot take it
  await page.getByLabel('Borrower card (GR number) or name').fill(walkin.gr_number);
  await page.getByTestId('find-borrower').click();
  await page.getByTestId('issue-desk').getByLabel('Book barcode').fill('RARE1');
  await page.getByTestId('issue-copy').click();
  await expect(page.getByTestId('issue-error')).toContainText('not available');

  await page.goto('/library/reservations');
  await expect(page.getByTestId('reservation-row').filter({ hasText: 'Queue Kid A' })).toContainText('Held for collection');
  await expect(page.getByTestId('reservation-row').filter({ hasText: 'Queue Kid B' })).toContainText('Queue position 1');
});
