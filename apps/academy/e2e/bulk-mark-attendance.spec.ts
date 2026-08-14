import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacherWithRoster(studentCount: number) {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@bulk-mark-e2e.test`;
  const teacherEmail = `teacher-${runId}@bulk-mark-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `bulk-mark-e2e-${runId}`,
    p_legal_name: `Bulk Mark E2E School ${runId}`,
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
      capacity: studentCount,
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

  const { error: e8 } = await admin.from('attendance_policy').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    start_time: '08:00',
    late_threshold_minutes: 15,
    lock_window_hours: 24,
  });
  if (e8) throw e8;

  return { ownerEmail, teacherEmail, password, sectionId: section!.id, studentCount };
}

async function admitAndEnrol(page: import('@playwright/test').Page, name: string) {
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

test('a zero-touch submit writes every active student present in one round trip', async ({ page, browser }) => {
  test.setTimeout(90_000);
  const { ownerEmail, teacherEmail, password, sectionId } = await seedOwnerAndClassTeacherWithRoster(3);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  for (const name of ['Bulk Kid One', 'Bulk Kid Two', 'Bulk Kid Three']) {
    await admitAndEnrol(page, name);
  }

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

  // AC1: exactly 2 interactions — load, then save — with zero taps on
  // any individual student row.
  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.locator('[data-testid^="register-row-"]')).toHaveCount(3);
  await expect(teacherPage.getByTestId('register-status-tap').first()).toHaveText('present');

  await teacherPage.getByTestId('register-save').click();
  await expect(teacherPage.getByText('Register saved — 3 student(s).')).toBeVisible();

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: rows } = await admin.from('attendance_day').select('status').eq('section_id', sectionId);
  expect(rows).toHaveLength(3);
  expect(rows?.every((r) => r.status === 'present')).toBe(true);

  await teacherContext.close();
});

test('the register is usable at a 360x640 mobile viewport with real tap targets', async ({ page, browser }) => {
  test.setTimeout(60_000);
  const { ownerEmail, teacherEmail, password } = await seedOwnerAndClassTeacherWithRoster(1);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await admitAndEnrol(page, 'Mobile Kid');

  const teacherContext = await browser.newContext({ viewport: { width: 360, height: 640 }, hasTouch: true });
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/dashboard$/);

  await teacherPage.goto('/attendance/register');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByTestId('register-load').click();

  const row = teacherPage.locator('[data-testid^="register-row-"]').first();
  await expect(row).toBeVisible();
  const rowBox = await row.boundingBox();
  expect(rowBox?.height).toBeGreaterThanOrEqual(48);

  const tapButton = row.getByTestId('register-status-tap');
  const tapBox = await tapButton.boundingBox();
  expect(tapBox?.height).toBeGreaterThanOrEqual(44);
  expect(tapBox?.width).toBeGreaterThanOrEqual(44);

  // The tap-cycle works with a real tap at this viewport, no dropdown,
  // no navigation.
  await tapButton.tap();
  await expect(tapButton).toHaveText('absent');
  await expect(teacherPage).toHaveURL(/\/attendance\/register$/);

  await teacherContext.close();
});
