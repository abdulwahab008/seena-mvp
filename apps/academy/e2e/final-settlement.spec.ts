import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs, userClient } from './support/hr-seed';

// FR-D17: the Accountant computes a leaver's settlement (the AC figures), approves it, and the PDF
// is rendered once: the second download returns the stored file with an identical SHA-256.

test('settlement lines match the AC figures and the approved PDF is served identically twice', async ({ page }) => {
  test.setTimeout(180000);
  const { db, tenantId, mkUser } = await seedHrTenant('settle-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const accountant = await mkUser('accountant', 'accountant');
  const leaver = await mkUser('leaver', 'subject_teacher', { staff: { doj: '2020-01-01' } });

  const { data: contract } = await db
    .from('staff_contract')
    .insert({ tenant_id: tenantId, staff_id: leaver.staffId, contract_type: 'permanent', start_date: '2026-01-01', notice_period_days: 30 })
    .select('id')
    .single();
  await db.from('staff_contract_pay').insert({ contract_id: contract!.id, gross_salary: 80000 });
  const { data: earned } = await db.from('leave_type').insert({ tenant_id: tenantId, code: 'EARNED', name_en: 'Earned leave', entitlement_days: 30, is_encashable: true, encashment_cap_days: 10 }).select('id').single();
  const { data: casual } = await db.from('leave_type').insert({ tenant_id: tenantId, code: 'CASUAL', name_en: 'Casual leave', entitlement_days: 10, is_encashable: false }).select('id').single();
  await db.from('leave_ledger').insert([
    { tenant_id: tenantId, staff_id: leaver.staffId, leave_type_id: earned!.id, entry_type: 'grant', days: 12 },
    { tenant_id: tenantId, staff_id: leaver.staffId, leave_type_id: casual!.id, entry_type: 'grant', days: 5 },
  ]);
  const hr$ = await userClient(hr.email);
  const { data: exitId, error } = await hr$.rpc('initiate_staff_exit', { p_staff_id: leaver.staffId!, p_exit_type: 'resignation', p_notice_date: '2026-08-15', p_last_working_date: '2026-08-20' });
  expect(error).toBeNull();

  await signInAs(page, accountant.email);
  await page.goto(`/staff/exits/${exitId}/settlement`);
  await page.getByTestId('compute-settlement').click();
  await expect(page.getByTestId('line-salary')).toContainText('51,612.90');
  await expect(page.getByTestId('line-leave_encashment')).toContainText('26,666.70');
  await expect(page.getByTestId('line-notice_recovery')).toContainText('66,666.75');
  await expect(page.getByTestId('settlement-net')).toContainText('-15,053.85');

  await page.getByTestId('approve-settlement').click();
  await expect(page.getByTestId('settlement-status')).toContainText('approved');

  const { data: st } = await db.from('staff_settlement').select('id').eq('exit_id', exitId as string).single();
  const first = await page.request.get(`/api/settlements/${st!.id}/pdf`);
  expect(first.status()).toBe(200);
  const firstHash = first.headers()['x-pdf-sha256'];
  expect(first.headers()['x-pdf-source']).toBe('rendered');
  const second = await page.request.get(`/api/settlements/${st!.id}/pdf`);
  expect(second.status()).toBe(200);
  expect(second.headers()['x-pdf-source']).toBe('served');
  expect(second.headers()['x-pdf-sha256']).toBe(firstHash);
  const { data: sealed } = await db.from('staff_settlement').select('pdf_sha256').eq('id', st!.id).single();
  expect(sealed!.pdf_sha256).toBe(firstHash);
});
