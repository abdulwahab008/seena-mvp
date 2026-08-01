import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacherWithLockedDay() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@att-correction-e2e.test`;
  const teacherEmail = `teacher-${runId}@att-correction-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `att-correction-e2e-${runId}`,
    p_legal_name: `Attendance Correction E2E School ${runId}`,
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

  const oldDate = new Date(Date.now() - 100 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  const { error: e7 } = await admin.from('section_class_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    staff_id: teacherUser.user.id,
    effective_from: oldDate,
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

  return { ownerEmail, teacherEmail, password, oldDate, tenantId: tenantId as string, campusId: campus!.id, sessionId: session!.id, sectionId: section!.id };
}

// enrolment has an AFTER INSERT trigger (build_fee_plan) that resolves
// the caller's tenant from the JWT — a raw service-role insert has no
// JWT and fails it. The student/enrolment must be created through the
// real, logged-in owner's UI (admit_student → enrol_student), same as
// every other e2e spec in this codebase that needs a real enrolment.
async function seedOldAttendanceDay(
  enrolmentId: string,
  args: { tenantId: string; campusId: string; sessionId: string; sectionId: string; oldDate: string }
) {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { error } = await admin.from('attendance_day').insert({
    tenant_id: args.tenantId,
    campus_id: args.campusId,
    session_id: args.sessionId,
    section_id: args.sectionId,
    enrolment_id: enrolmentId,
    attendance_date: args.oldDate,
    status: 'absent',
    source: 'web',
  });
  if (error) throw error;
}

test('a class teacher requests a correction on a locked date; an owner approves it and the change is permanently audited', async ({
  page,
  browser,
}) => {
  const { ownerEmail, teacherEmail, password, oldDate, tenantId, campusId, sessionId, sectionId } = await seedOwnerAndClassTeacherWithLockedDay();

  // The owner admits and enrols the student through the real UI first —
  // create_student()/enrol_student() both need a real JWT, and GR
  // allocation only happens inside them.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Correction Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Correction Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: enrolment, error: enrolFetchError } = await admin.from('enrolment').select('id').eq('student_id', studentId!).single();
  if (enrolFetchError || !enrolment) throw enrolFetchError ?? new Error('enrolment not found after UI enrol');
  await seedOldAttendanceDay(enrolment.id, { tenantId, campusId, sessionId, sectionId, oldDate });

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
  await teacherPage.getByTestId('register-date').fill(oldDate);
  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.getByTestId('register-locked-banner')).toBeVisible();

  const row = teacherPage.locator('[data-testid^="register-row-"]').filter({ hasText: 'Correction Kid' });
  await row.getByTestId(/request-correction-open-/).click();
  await row.getByTestId(/correction-status-trigger-/).click();
  await teacherPage.getByRole('option', { name: 'present', exact: true }).click();
  await row.getByTestId(/correction-reason-/).fill('Was marked absent by mistake, parent brought a doctor note');
  await row.getByTestId(/correction-submit-/).click();
  await expect(teacherPage.getByText('Correction requested.')).toBeVisible();

  // The owner (already signed in) reviews and approves it.
  await page.goto('/attendance/corrections');
  await page.waitForLoadState('networkidle');
  const pendingRow = page.locator('[data-testid^="correction-row-"]').filter({ hasText: 'Correction Kid' });
  await expect(pendingRow).toBeVisible();
  await expect(pendingRow).toContainText('absent');
  await expect(pendingRow).toContainText('present');

  await pendingRow.getByTestId(/correction-decision-note-/).fill('Confirmed with the parent, note is on file');
  await pendingRow.getByTestId(/correction-approve-/).click();
  await expect(page.getByText('Correction approved.')).toBeVisible();

  // Reloading shows it moved to Decided, marked approved.
  await page.goto('/attendance/corrections');
  await page.waitForLoadState('networkidle');
  const decidedRow = page.locator('[data-testid^="correction-row-"]').filter({ hasText: 'Correction Kid' });
  await expect(decidedRow.getByTestId(/correction-status-/)).toHaveText('approved');

  // The register itself now shows the corrected status — reload the
  // same (still-locked) date and confirm the register agrees.
  await teacherPage.getByTestId('register-load').click();
  const correctedRow = teacherPage.locator('[data-testid^="register-row-"]').filter({ hasText: 'Correction Kid' });
  await expect(correctedRow.getByTestId(/register-current-status-/)).toHaveText('present', { timeout: 10_000 });

  await teacherContext.close();
});
