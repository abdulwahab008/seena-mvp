import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacherWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@att-lock-e2e.test`;
  const teacherEmail = `teacher-${runId}@att-lock-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `att-lock-e2e-${runId}`,
    p_legal_name: `Attendance Lock E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;
  const { error: e3b } = await admin
    .from('user_campus')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e3b) throw e3b;

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'class_teacher', full_name: 'Class Teacher' });
  if (e5) throw e5;
  const { error: e5b } = await admin
    .from('user_campus')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e5b) throw e5b;

  const { data: section, error: e6 } = await admin
    .from('class_section')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      name: 'A',
      capacity: 30,
    })
    .select('id')
    .single();
  if (e6) throw e6;

  const { error: e7 } = await admin.from('section_class_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    staff_id: teacherUser.user.id,
    effective_from: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10),
  });
  if (e7) throw e7;

  // A wide 24h window: today (whenever "now" happens to be within the
  // day) is always still open — start_time 08:00 + 24h means the
  // deadline is always tomorrow 08:00. A date 30 days ago is always
  // long past any such deadline, regardless of what time the suite runs.
  const { error: e8 } = await admin.from('attendance_policy').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    start_time: '08:00',
    late_threshold_minutes: 15,
    lock_window_hours: 24,
  });
  if (e8) throw e8;

  return { ownerEmail, teacherEmail, password };
}

test('a locked date refuses edits and shows a banner; an owner can force an early lock', async ({ page, browser }) => {
  const { ownerEmail, teacherEmail, password } = await seedOwnerAndClassTeacherWithSection();
  const oldDate = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Lock Test Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Lock Test Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // AC1/AC3: a class teacher hitting a date whose window has long since
  // elapsed sees the locked banner, and no Save control at all.
  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/dashboard$/);

  await teacherPage.goto('/attendance/register');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByTestId('register-date').fill(oldDate);
  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.getByTestId('register-locked-banner')).toBeVisible();
  await expect(teacherPage.getByTestId('register-locked-banner')).toContainText('Locked');
  await expect(teacherPage.getByTestId('register-save')).toHaveCount(0);
  // A class teacher (not an admin role) never sees the manual lock control.
  await expect(teacherPage.getByTestId('register-lock-now')).toHaveCount(0);

  // AC3: an Owner can force an early lock on a date that's still open,
  // and the register immediately reflects it as locked.
  await page.goto('/attendance/register');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('register-load').click();
  await expect(page.getByTestId('register-locked-banner')).toHaveCount(0);
  await expect(page.getByTestId('register-lock-now')).toBeVisible();
  await page.getByTestId('register-lock-now').click();
  await expect(page.getByText('Locked.')).toBeVisible();
  await expect(page.getByTestId('register-locked-banner')).toBeVisible();
  await expect(page.getByTestId('register-save')).toHaveCount(0);

  await teacherContext.close();
});
