import { test, expect, type Page } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

// FR-D16: HR starts a resignation (notice shortfall flagged), completion is blocked until each department signs off,
// only the owning department can clear its item, HR waivers need a real reason, and completion revokes access.

const iso = (offsetDays: number) => new Date(Date.now() + offsetDays * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

test('an exit is blocked until every department signs off, then access is revoked', async ({ page, browser, baseURL }) => {
  test.setTimeout(180000);
  const { db, tenantId, mkUser } = await seedHrTenant('exit-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const librarian = await mkUser('librarian', 'librarian');
  const accountant = await mkUser('accountant', 'accountant');
  const principal = await mkUser('principal', 'principal');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  await db.from('staff_contract').insert({ tenant_id: tenantId, staff_id: teacher.staffId, contract_type: 'permanent', start_date: '2020-01-01', notice_period_days: 30 });

  await signInAs(page, hr.email);
  await page.goto(`/staff/${teacher.staffId}`);
  await page.getByLabel('Notice given on').fill(iso(-6));
  await page.getByLabel('Last working date').fill(iso(-1));
  await page.getByTestId('start-exit').click();
  await expect(page.getByTestId('notice-shortfall')).toContainText('25 day(s)');

  await page.getByTestId('complete-exit').click();
  await expect(page.getByTestId('complete-error')).toContainText('Library dues');
  await expect(page.getByTestId('clear-library_dues')).toHaveCount(0); // HR does not own this item

  await page.getByTestId('open-waive-it_assets').click();
  await page.getByLabel('Waiver reason for it_assets').fill('too short');
  await page.getByTestId('waive-it_assets').click();
  await expect(page.getByTestId('clearance-it_assets')).toContainText('at least 10 characters');
  await page.getByLabel('Waiver reason for it_assets').fill('Laptop written off against final pay');
  await page.getByTestId('waive-it_assets').click();
  await expect(page.getByTestId('clearance-it_assets')).toContainText('waived');
  await page.getByTestId('clear-id_card_uniform').click();
  await expect(page.getByTestId('clearance-id_card_uniform')).toContainText('cleared');

  const exitUrl = page.url();
  const clearAs = async (email: string, codes: string[]) => {
    const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
    const p: Page = await ctx.newPage();
    await signInAs(p, email);
    await p.goto(exitUrl);
    for (const code of codes) {
      await p.getByTestId(`clear-${code}`).click();
      await expect(p.getByTestId(`clearance-${code}`)).toContainText('cleared');
    }
    await ctx.close();
  };
  await clearAs(librarian.email, ['library_dues']);
  await clearAs(accountant.email, ['fee_counter_float', 'loans_advances']);
  await clearAs(principal.email, ['academic_handover']);

  await page.goto(exitUrl);
  await page.getByTestId('complete-exit').click();
  await expect(page.getByTestId('exit-status')).toHaveText('completed');
  const { data: user } = await db.from('app_user').select('status').eq('user_id', teacher.userId).single();
  expect(user!.status).toBe('terminated');
  const { data: staffRow } = await db.from('staff').select('employment_status').eq('id', teacher.staffId!).single();
  expect(staffRow!.employment_status).toBe('exited');
});
