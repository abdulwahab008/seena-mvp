import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacherWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@att-register-e2e.test`;
  const teacherEmail = `teacher-${runId}@att-register-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `att-register-e2e-${runId}`,
    p_legal_name: `Attendance Register E2E School ${runId}`,
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

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'class_teacher', full_name: 'Class Teacher' });
  if (e5) throw e5;
  // The JWT's campus_ids claim is derived from user_campus — without a
  // row here the class teacher's RLS reads of class_section (and
  // anything scoped by campus_ids) see nothing at all.
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

  // section_class_teacher's own assign_class_teacher() RPC checks JWT
  // claims a service-role call never carries — seeded directly, the
  // established pattern this session uses throughout for prerequisite
  // data unreachable via authenticated RPC.
  const { error: e7 } = await admin.from('section_class_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    staff_id: teacherUser.user.id,
    effective_from: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10),
  });
  if (e7) throw e7;

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

test('a class teacher marks the daily register for their assigned section', async ({ page, browser }) => {
  const { ownerEmail, teacherEmail, password } = await seedOwnerAndClassTeacherWithSection();

  // The owner admits and enrols two students through the real UI first —
  // create_student()/enrol_student() both check JWT claims a service-role
  // seed can't carry, and GR allocation only ever happens inside them.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  for (const name of ['Present Kid', 'Late Kid']) {
    await page.goto('/students');
    await page.waitForLoadState('networkidle');
    await page.getByTestId('student-gender-trigger').click();
    await page.getByRole('option', { name: 'Male', exact: true }).click();
    await page.getByLabel('Name', { exact: true }).fill(name);
    await page.getByLabel('Date of birth').fill('2015-04-12');
    await page.getByRole('button', { name: 'Admit student' }).click();
    await expect(page.getByText(`${name} admitted.`)).toBeVisible();
    await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

    await page.getByTestId('enrol-section-trigger').click();
    await page.getByRole('option', { name: 'Class 1 · A' }).click();
    await page.getByRole('button', { name: 'Enrol into section' }).click();
    await expect(page.getByText('Enrolled.')).toBeVisible();
  }

  // A fully separate session for the class teacher.
  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/campuses$/);

  await teacherPage.goto('/attendance/register');
  await teacherPage.waitForLoadState('networkidle');

  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.locator('[data-testid^="register-row-"]')).toHaveCount(2);

  const lateRow = teacherPage.locator('[data-testid^="register-row-"]').filter({ hasText: 'Late Kid' });
  await lateRow.getByRole('combobox').click();
  await teacherPage.getByRole('option', { name: 'late', exact: true }).click();

  await teacherPage.getByTestId('register-save').click();
  await expect(teacherPage.getByText('Register saved — 2 student(s).')).toBeVisible();

  // Reloading the same date pre-fills the just-saved statuses.
  await teacherPage.getByTestId('register-load').click();
  await expect(lateRow.getByRole('combobox')).toContainText('late');

  await teacherContext.close();
});
