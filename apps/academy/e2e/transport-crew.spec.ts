import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-P03: licence class and expiry enforced at assignment, duplicate CNIC rejected, CNIC masked for a class teacher.

test('crew register enforces licence rules and masks the CNIC from a class teacher', async ({ page, browser, baseURL }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'crew-e2e');

  const route = await owner$.rpc('save_transport_route', { p_campus_id: campusId, p_code: 'R-01', p_name: 'North', p_shift: 'morning' });
  const bus = await owner$.rpc('save_transport_vehicle', { p_campus_id: campusId, p_reg_no: 'BUS-42', p_seat_capacity: 42 });
  // The documents must outlive the assignment date below (2030-08-10), otherwise the vehicle block
  // (VEHICLE_BLOCKED: fitness certificate expired) fires before the licence-class check is reached.
  for (const t of ['fitness', 'insurance', 'token_tax']) {
    const doc = await owner$.rpc('add_vehicle_document', { p_vehicle_id: bus.data as string, p_doc_type: t, p_expires_on: '2031-12-31' });
    expect(doc.error).toBeNull();
  }
  expect(route.error).toBeNull();
  expect(bus.error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/transport/crew');
  const form = page.getByTestId('crew-form');
  await form.getByLabel(/Full name/).fill('Aslam');
  await form.getByLabel(/^CNIC/).fill('35202-1234567-1');
  await form.getByLabel(/^Role/).selectOption('driver');
  await form.getByLabel(/Licence no/).fill('LH-001');
  await form.getByLabel(/Licence class/).selectOption('LTV');
  await form.getByLabel(/Licence expires/).fill('2030-08-15');
  await page.getByTestId('crew-form-submit').click();
  await expect(page.getByTestId('crew-row')).toHaveCount(1);

  // Same CNIC again: DUPLICATE_CNIC.
  await form.getByLabel(/Full name/).fill('Aslam Two');
  await form.getByLabel(/^CNIC/).fill('35202-1234567-1');
  await form.getByLabel(/^Role/).selectOption('conductor');
  await page.getByTestId('crew-form-submit').click();
  await expect(page.getByTestId('crew-form-error')).toContainText('DUPLICATE_CNIC');

  // An LTV driver on the 42-seat bus is refused.
  await page.goto('/transport/assignments');
  const assign = page.getByTestId('assign-form');
  await assign.getByLabel(/^Route/).selectOption({ index: 1 });
  await assign.getByLabel(/^Vehicle/).selectOption({ index: 1 });
  await assign.getByLabel(/^Driver/).selectOption({ index: 1 });
  await assign.getByLabel(/^From/).fill('2030-08-10');
  await page.getByTestId('assign-form-submit').click();
  await expect(page.getByTestId('assign-form-error')).toContainText('LICENCE_CLASS_INSUFFICIENT');

  // A class teacher sees the CNIC masked.
  const teacherEmail = `teacher-${tenant.slice(0, 8)}@crew-e2e.test`;
  const { data: u } = await db.auth.admin.createUser({ email: teacherEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: u.user!.id, tenant_id: tenant, app_role: 'class_teacher', full_name: 'Class Teacher' });
  await db.from('user_campus').insert({ user_id: u.user!.id, tenant_id: tenant, campus_id: campusId });
  const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const tp = await ctx.newPage();
  await tp.goto('/login');
  await tp.waitForLoadState('networkidle');
  await tp.getByLabel('Email').fill(teacherEmail);
  await tp.getByLabel('Password').fill(SEED_PASSWORD);
  await tp.getByRole('button', { name: 'Sign in' }).click();
  await expect(tp).not.toHaveURL(/\/login/);
  await tp.goto('/transport/crew');
  await expect(tp.getByTestId('crew-cnic').first()).toHaveText('35202-xxxxxxx-1');
  await ctx.close();
});
