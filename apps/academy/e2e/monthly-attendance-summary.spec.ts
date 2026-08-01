import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacherWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@monthly-summary-e2e.test`;
  const teacherEmail = `teacher-${runId}@monthly-summary-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `monthly-summary-e2e-${runId}`,
    p_legal_name: `Monthly Summary E2E School ${runId}`,
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

  return { ownerEmail, teacherEmail, password, tenantId: tenantId as string, campusId: campus!.id, sessionId: session!.id, sectionId: section!.id };
}

test('an owner recomputes a monthly attendance summary and a class teacher cannot', async ({ page, browser }) => {
  const { ownerEmail, teacherEmail, password, tenantId, campusId, sessionId, sectionId } = await seedOwnerAndClassTeacherWithSection();

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
  await page.getByLabel('Name', { exact: true }).fill('Summary Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Summary Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // A direct seed, not a UI mark — this spec is about the summary
  // computation and its UI, not attendance marking (already covered by
  // daily-attendance-register.spec.ts); today's date is used so the
  // enrolment's own joined_on (also today, set by enrol_student()) never
  // clips it out of the working-day window.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: enrolment, error: enrolFetchError } = await admin.from('enrolment').select('id').eq('student_id', studentId!).single();
  if (enrolFetchError || !enrolment) throw enrolFetchError ?? new Error('enrolment not found after UI enrol');
  const today = new Date().toISOString().slice(0, 10);
  const { error: seedError } = await admin.from('attendance_day').insert({
    tenant_id: tenantId,
    campus_id: campusId,
    session_id: sessionId,
    section_id: sectionId,
    enrolment_id: enrolment.id,
    attendance_date: today,
    status: 'present',
    source: 'web',
  });
  if (seedError) throw seedError;

  const year = new Date().getFullYear();
  const month = new Date().getMonth() + 1;

  await page.goto('/attendance/monthly-summary');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('summary-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByTestId('summary-year').fill(String(year));
  await page.getByTestId('summary-month').fill(String(month));
  await page.getByTestId('summary-load').click();
  await expect(page.getByText('No summary computed yet for this section/month.')).toBeVisible();

  await page.getByTestId('summary-recompute').click();
  await expect(page.getByText('Recomputed 1 enrolment(s).')).toBeVisible();

  await expect(page.getByTestId(`summary-row-${enrolment.id}`)).toBeVisible();
  await expect(page.getByTestId(`summary-pct-${enrolment.id}`)).toContainText('%');
  await expect(page.getByTestId(`summary-pct-${enrolment.id}`)).not.toHaveText('—');

  // A class teacher (not an admin role) never sees the Recompute control,
  // but the read-only summary itself is still visible to them.
  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/campuses$/);

  await teacherPage.goto('/attendance/monthly-summary');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByTestId('summary-section-trigger').click();
  await teacherPage.getByRole('option', { name: 'Class 1 · A' }).click();
  await teacherPage.getByTestId('summary-year').fill(String(year));
  await teacherPage.getByTestId('summary-month').fill(String(month));
  await teacherPage.getByTestId('summary-load').click();
  await expect(teacherPage.getByTestId(`summary-row-${enrolment.id}`)).toBeVisible();
  await expect(teacherPage.getByTestId('summary-recompute')).toHaveCount(0);

  await teacherContext.close();
});
