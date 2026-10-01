import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-Q05: the Principal publishes a full week; a parent reads it, requests mess-off, and is refused inside the notice period.

test('publish the weekly menu; a parent requests mess-off with and without enough notice', async ({ page, browser, baseURL }) => {
  test.setTimeout(180000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'mess-e2e');
  const block = await owner$.rpc('create_hostel_block', { p_campus_id: campusId, p_code: 'IQ', p_name: 'Iqbal Block', p_gender: 'male', p_rooms: 2, p_beds_per_room: 4 });
  expect(block.error).toBeNull();
  const { data: stu } = await db.from('student').select('id, gr_number').eq('tenant_id', tenant).single();
  const { data: bed } = await db.from('hostel_bed').select('id').eq('tenant_id', tenant).eq('bed_code', 'IQ-101-B1').single();
  expect((await owner$.rpc('allocate_bed', { p_student_id: stu!.id, p_bed_id: bed!.id, p_from: '2026-01-05' })).error).toBeNull();

  const parentEmail = `parent-${tenant.slice(0, 8)}@mess-e2e.test`;
  const { data: pu } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: g } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Father One', auth_user_id: pu.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: stu!.id, guardian_id: g!.id, relationship: 'father', is_primary: true, receives_billing: true });
  await db.from('app_user').insert({ user_id: pu.user!.id, tenant_id: tenant, app_role: 'parent', full_name: 'Father One' });

  const signIn = async (p: import('@playwright/test').Page, mail: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(mail);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await expect(p).not.toHaveURL(/\/login/);
  };

  await signIn(page, email);
  await page.goto('/hostel/mess');
  const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  // Leave one slot empty first: publishing is refused.
  for (const d of days) {
    for (const m of ['breakfast', 'lunch', 'dinner']) {
      if (d === 'Sunday' && m === 'dinner') continue;
      await page.getByLabel(`${d} ${m}`, { exact: true }).fill(`${m} on ${d}`);
    }
  }
  await page.getByTestId('publish-menu').click();
  await expect(page.getByTestId('menu-error')).toContainText('MENU_INCOMPLETE');
  await page.getByLabel('Sunday dinner', { exact: true }).fill('Biryani');
  await page.getByTestId('publish-menu').click();
  await expect(page.getByText(/published/i).first()).toBeVisible();

  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signIn(pp, parentEmail);
  await pp.goto('/portal/hostel');
  await expect(pp.getByTestId('menu-slot')).toHaveCount(21);
  await expect(pp.getByTestId('menu-published')).toBeVisible();

  const form = pp.locator('[data-testid^="mess-off-form-"]').first();
  const soon = new Date(Date.now() + 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  await form.getByLabel('First day away').fill(soon);
  await form.getByLabel('Last day away').fill(soon);
  await form.locator('button[type="submit"]').click();
  await expect(form.getByRole('alert')).toContainText('NOTICE_PERIOD_NOT_MET');

  const later = new Date(Date.now() + 6 * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  await form.getByLabel('First day away').fill(later);
  await form.getByLabel('Last day away').fill(later);
  await form.locator('button[type="submit"]').click();
  await expect(pp.getByTestId('my-mess-off')).toHaveCount(1);
  await pctx.close();
});
