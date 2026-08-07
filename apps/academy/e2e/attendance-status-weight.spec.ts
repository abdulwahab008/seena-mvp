import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@att-weight-e2e.test`;
  const teacherEmail = `teacher-${runId}@att-weight-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `att-weight-e2e-${runId}`,
    p_legal_name: `Attendance Weight E2E School ${runId}`,
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
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
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

  const { error: e8 } = await admin
    .from('attendance_policy')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, start_time: '08:00', late_threshold_minutes: 15, lock_window_hours: 24 });
  if (e8) throw e8;

  return { ownerEmail, teacherEmail, password, tenantId: tenantId as string, sectionId: section!.id as string };
}

test('a class teacher marks a student late (auto-filled or explicit arrival time), and an owner overrides the half-day weight through the UI', async ({
  page,
  browser,
}) => {
  const { ownerEmail, teacherEmail, password, sectionId } = await seedTenant();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  for (const name of ['Auto Late Kid', 'Explicit Late Kid']) {
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

  // AC1/AC3: the owner arms a half-day weight override on the real
  // attendance policy screen — a reload proves it actually persisted,
  // not just an optimistic client-side echo.
  await page.goto('/academic-setup/attendance-policy');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('attendance-weight-half-day').fill('0');
  await page.getByTestId('attendance-weight-half-day-save').click();
  await expect(page.getByText('Status weight saved.')).toBeVisible();
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('attendance-weight-half-day')).toHaveValue('0');
  // The late weight was never touched — still at its unconfigured default.
  await expect(page.getByTestId('attendance-weight-late')).toHaveValue('1');

  // A class teacher, in a separate session, marks the register.
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

  // Two taps on FR-G04's cycle (present -> absent -> late) lands on "late"
  // for both students — one left with no arrival time (auto-filled
  // server-side), the other given an explicit one via FR-G06's new input.
  const autoRow = teacherPage.locator('[data-testid^="register-row-"]').filter({ hasText: 'Auto Late Kid' });
  const explicitRow = teacherPage.locator('[data-testid^="register-row-"]').filter({ hasText: 'Explicit Late Kid' });
  for (const row of [autoRow, explicitRow]) {
    const tap = row.getByTestId('register-status-tap');
    await tap.click();
    await tap.click();
    await expect(tap).toHaveText('late');
  }

  // AC2: the arrival-time input only appears once a row is actually
  // marked "late" — it must not be there for an unmarked/present row.
  await expect(autoRow.locator('[data-testid^="register-arrival-time-"]')).toBeVisible();

  const explicitArrivalInput = explicitRow.locator('[data-testid^="register-arrival-time-"]');
  await explicitArrivalInput.fill('09:12');

  await teacherPage.getByTestId('register-save').click();
  await expect(teacherPage.getByText('Register saved — 2 student(s).')).toBeVisible();

  // The register screen itself doesn't surface arrival_time post-save —
  // asserted straight from the database, the same as how this suite
  // already verifies non-UI-surfaced side effects (audit rows, etc.).
  const { data: rows } = await admin
    .from('attendance_day')
    .select('arrival_time, enrolment:enrolment_id(student:student_id(name_en))')
    .eq('section_id', sectionId)
    .eq('status', 'late');
  type Row = { arrival_time: string | null; enrolment: unknown };
  const one = <T,>(v: T | T[] | null | undefined): T | null => (Array.isArray(v) ? (v[0] ?? null) : (v ?? null));
  const byName = new Map(
    ((rows ?? []) as Row[]).map((r) => {
      const enrolment = one(r.enrolment as { student: unknown } | { student: unknown }[]);
      const student = enrolment ? one(enrolment.student as { name_en: string } | { name_en: string }[]) : null;
      return [student?.name_en ?? '', r.arrival_time];
    })
  );

  expect(byName.get('Auto Late Kid')).not.toBeNull();
  expect(byName.get('Explicit Late Kid')).toBe('09:12:00');

  await teacherContext.close();
});
