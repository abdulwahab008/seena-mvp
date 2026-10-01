import { test, expect } from '@playwright/test';
import { seedLibraryTenant, signInAs } from './support/library-seed';

// FR-O07: the nightly job accrues capped, idempotent fines; the borrower is flagged blocked; the Accountant waives
// (with a reason) or settles; rows are never deleted.

const karachiDate = (offsetDays: number) => new Date(Date.now() + offsetDays * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

test('the nightly accrual is capped and idempotent; the Accountant settles and waives', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, mk } = await seedLibraryTenant('libfine-e2e');
  const accountant = await mk('accountant', 'accountant');

  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const mkStudent = async (name: string) => {
    const { data: s } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: name, p_dob: '2015-03-03', p_gender: 'male' });
    await owner$.rpc('enrol_student', { p_section_id: section!.id, p_student_id: s as string });
    return s as string;
  };
  const late = await mkStudent('Very Late Kid');
  const slightly = await mkStudent('Slightly Late Kid');

  const policy = { tenant_id: tenant, role: 'student', max_loans: 2, loan_days: 14, max_renewals: 1, fine_per_day: 500, fine_cap: 50000, block_threshold: 30000, effective_from: '2026-01-01' };
  await db.from('library_borrower_policy').insert(policy);
  const { data: title } = await db.from('library_title').insert({ tenant_id: tenant, title: 'Overdue Atlas' }).select('id').single();
  const { data: copies } = await db
    .from('library_copy')
    .insert([1, 2].map((n) => ({ tenant_id: tenant, campus_id: campusId, title_id: title!.id, accession_no: `ACC-${n}`, barcode: `BC${n}`, status: 'issued' })))
    .select('id, barcode');
  const copyId = (bc: string) => copies!.find((c) => c.barcode === bc)!.id;
  const snapshot = { fine_per_day: 500, fine_cap: 50000, block_threshold: 30000, max_loans: 2, loan_days: 14, max_renewals: 1, role: 'student' };
  await db.from('library_loan').insert([
    { tenant_id: tenant, campus_id: campusId, copy_id: copyId('BC1'), borrower_id: late, borrower_role: 'student', issued_at: new Date(Date.now() - 120 * 86_400_000).toISOString(), due_on: karachiDate(-100), policy_snapshot: snapshot },
    { tenant_id: tenant, campus_id: campusId, copy_id: copyId('BC2'), borrower_id: slightly, borrower_role: 'student', issued_at: new Date(Date.now() - 20 * 86_400_000).toISOString(), due_on: karachiDate(-6), policy_snapshot: snapshot },
  ]);

  const today = karachiDate(0);
  for (let i = 0; i < 3; i++) {
    const { error } = await db.rpc('accrue_library_fines', { p_date: today });
    expect(error).toBeNull();
  }

  await signInAs(page, accountant.email);
  await page.goto('/library/fines');
  const veryLate = page.getByTestId('fine-row').filter({ hasText: 'Very Late Kid' });
  await expect(veryLate).toContainText('PKR 500');
  await expect(veryLate).toContainText('Blocked');
  const slight = page.getByTestId('fine-row').filter({ hasText: 'Slightly Late Kid' });
  await expect(slight).toContainText('PKR 30');
  await expect(slight).toContainText('Can borrow');

  // a waiver needs a reason
  await slight.getByTestId('waive-fines').click();
  await expect(slight.getByTestId('fine-error')).toContainText('reason');
  await slight.getByLabel(/Waiver reason/).fill('Hardship approved by the Principal');
  await slight.getByTestId('waive-fines').click();
  await expect(page.getByTestId('fine-row').filter({ hasText: 'Slightly Late Kid' })).toHaveCount(0);

  await veryLate.getByTestId('settle-fines').click();
  await expect(page.getByTestId('fine-row')).toHaveCount(0);

  const { data: rows } = await db.from('library_fine').select('status').eq('tenant_id', tenant);
  expect(rows!.filter((r) => r.status === 'waived')).toHaveLength(6);
  expect(rows!.filter((r) => r.status === 'settled')).toHaveLength(100);
});
