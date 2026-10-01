import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O05: returning a late book finalises the fine from the loan's own policy snapshot; a damaged return goes
// to repair; a barcode with no open loan is refused.

const karachiDate = (offsetDays: number) => {
  const d = new Date(Date.now() + offsetDays * 86_400_000);
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
};

test('returning books finalises the fine, sends damaged copies to repair and refuses a scan with no loan', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, mk } = await seedLibraryTenant('libreturn-e2e');
  const librarian = await mk('librarian', 'librarian');

  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { data: s } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: 'Late Kid', p_dob: '2015-03-03', p_gender: 'male' });
  await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: s as string });

  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Chemistry 10' }).select('id').single();
  const { data: copies } = await db
    .from('library_copy')
    .insert([1, 2, 3].map((n) => ({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: `ACC-${n}`, barcode: `BC${n}`, status: n < 3 ? 'issued' : 'available' })))
    .select('id, barcode');
  const snapshot = { fine_per_day: 500, fine_cap: 50000, loan_days: 14, max_loans: 2, max_renewals: 1, role: 'student' };
  for (const c of (copies ?? []).filter((x) => x.barcode !== 'BC3')) {
    await db.from('library_loan').insert({
      tenant_id: tenant, campus_id: campusId, copy_id: c.id, borrower_id: s as string, borrower_role: 'student',
      issued_at: new Date(Date.now() - 21 * 86_400_000).toISOString(), due_on: karachiDate(-7), policy_snapshot: snapshot,
    });
  }

  await signInAs(page, librarian.email);
  await page.goto('/library/circulation');

  await page.getByTestId('return-desk').getByLabel('Book barcode').fill('BC1');
  await page.getByTestId('return-copy').click();
  await expect(page.getByTestId('return-ok')).toContainText('Late fine PKR 35 (7 days late)');
  await expect(page.getByTestId('return-ok')).toContainText('Back on the shelf');

  await page.getByTestId('return-desk').getByLabel('Book barcode').fill('BC2');
  await page.getByLabel('Condition').selectOption('damaged');
  await page.getByTestId('return-copy').click();
  await expect(page.getByTestId('return-ok')).toContainText('Sent to repair');
  const { data: bc2 } = await db.from('library_copy').select('status').eq('tenant_id', tenant).eq('barcode', 'BC2').single();
  expect(bc2!.status).toBe('in_repair');

  await page.getByTestId('return-desk').getByLabel('Book barcode').fill('BC3');
  await page.getByTestId('return-copy').click();
  await expect(page.getByTestId('return-error')).toContainText('no open loan');
  const { data: bc3 } = await db.from('library_copy').select('status').eq('tenant_id', tenant).eq('barcode', 'BC3').single();
  expect(bc3!.status).toBe('available');
});
