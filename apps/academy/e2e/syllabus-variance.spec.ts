import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H12: the Principal sees a class-subject behind plan, refreshes the grid, and acknowledges it with a reason.

test('the Principal sees a behind class-subject and acknowledges it with a reason', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(0, 'variance-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subjects } = await db
    .from('subject')
    .insert([
      { tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' },
      { tenant_id: tenant, code: 'MTH', name_en: 'Maths', name_ur: 'ریاضی' },
    ])
    .select('id, code');
  const phy = subjects!.find((s) => s.code === 'PHY')!;
  const mth = subjects!.find((s) => s.code === 'MTH')!;
  const lastMonth = new Date();
  lastMonth.setUTCMonth(lastMonth.getUTCMonth() - 1, 1);
  const target = lastMonth.toISOString().slice(0, 7) + '-01';
  // Physics has a plan whose chapters are all overdue and none is covered; Maths has no target months.
  const { error: e1 } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: phy.id, p_board: 'FBISE',
    p_units: [{ title: 'Motion', planned_periods: 10, target_month: target }, { title: 'Force', planned_periods: 10, target_month: target }],
  });
  expect(e1).toBeNull();
  const { error: e2 } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: mth.id, p_board: 'FBISE',
    p_units: [{ title: 'Algebra', planned_periods: 10 }],
  });
  expect(e2).toBeNull();

  const email = `principal-${tenant.slice(0, 8)}@variance-e2e.test`;
  const { data: created } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: created.user!.id, tenant_id: tenant, app_role: 'principal', full_name: 'The Principal' });
  await db.from('user_campus').insert({ user_id: created.user!.id, tenant_id: tenant, campus_id: campusId });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/syllabus-variance');
  await page.getByTestId('refresh-variance').click();
  await expect(page.getByTestId('variance-row')).toHaveCount(2);
  const physics = page.getByTestId('variance-row').filter({ hasText: 'Physics' });
  await expect(physics).toContainText('Behind');
  await expect(physics).toContainText('-100');
  const maths = page.getByTestId('variance-row').filter({ hasText: 'Maths' });
  await expect(maths).toContainText('No plan');
  await expect(page.getByTestId('count-behind')).toContainText('1');

  await physics.getByLabel('Reason').fill('Schools closed for floods');
  await physics.getByTestId('acknowledge').click();
  await expect(page.getByTestId('ack-reason')).toContainText('Schools closed for floods');
});
