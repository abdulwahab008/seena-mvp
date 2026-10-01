import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-G03: a subject teacher marks their own period and cannot open anyone else's.

test('a teacher marks their own period and is refused another', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(2, 'period-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();
  const { error: policyError } = await owner$.rpc('set_attendance_policy', { p_campus_id: campusId, p_session_id: session!.id, p_mode: 'period', p_lock_window_hours: 720 });
  expect(policyError).toBeNull();

  const teacherEmail = `teacher-${tenant.slice(0, 8)}@period-e2e.test`;
  const { data: teacher } = await db.auth.admin.createUser({ email: teacherEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: teacher.user!.id, tenant_id: tenant, app_role: 'subject_teacher', full_name: 'Period Teacher' });
  await db.from('user_campus').insert({ user_id: teacher.user!.id, tenant_id: tenant, campus_id: campusId });

  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
  const day = new Date(today + 'T00:00:00Z');
  if (day.getUTCDay() === 0) day.setUTCDate(day.getUTCDate() - 1);
  const date = day.toISOString().slice(0, 10);
  const weekday = day.getUTCDay();

  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { data: version } = await db
    .from('timetable_version')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, shift: 'MORNING', name: 'E2E', status: 'PUBLISHED', published_at: new Date().toISOString(), version_no: 1 })
    .select('id')
    .single();
  const slotBase = { tenant_id: tenant, campus_id: campusId, timetable_version_id: version!.id, section_id: section!.id, weekday, subject_id: subject!.id };
  const { data: mine } = await db.from('timetable_slot').insert({ ...slotBase, period_no: 4, staff_id: teacher.user!.id }).select('id').single();
  const { data: other } = await db.from('timetable_slot').insert({ ...slotBase, period_no: 5, staff_id: null }).select('id').single();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(teacherEmail);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto(`/attendance/periods?date=${date}`);
  await expect(page.getByTestId('period-slot')).toHaveCount(1);
  await page.getByTestId('period-slot').click();
  await expect(page.getByTestId('period-student')).toHaveCount(2);
  await page.getByLabel(/Status for/).first().selectOption('absent');
  await page.getByTestId('period-save').click();
  await expect(page.getByTestId('period-slot')).toContainText('2 marked');

  const { data: rows } = await db.from('attendance_period').select('status').eq('timetable_slot_id', mine!.id);
  expect(rows?.map((r) => r.status).sort()).toEqual(['absent', 'present']);

  await page.goto(`/attendance/periods?date=${date}&slot=${other!.id}`);
  await expect(page.getByTestId('period-not-assigned')).toHaveText('You are not assigned to this period.');
});
