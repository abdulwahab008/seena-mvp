import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSection() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@absentee-sms-e2e.test`;
  const teacherEmail = `teacher-${runId}@absentee-sms-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `absentee-sms-e2e-${runId}`,
    p_legal_name: `Absentee SMS E2E School ${runId}`,
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

test('an owner runs absentee notifications and sees a queued message plus a no-contact exception', async ({ page }) => {
  const { ownerEmail, password, tenantId, campusId, sessionId, sectionId } = await seedOwnerWithSection();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Two students: one with a contactable guardian, one without — admit
  // both through the real UI (enrolment's own AFTER INSERT trigger needs
  // a JWT, the established gotcha every e2e spec in this session works
  // around the same way).
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Absent Kid With Phone');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Absent Kid With Phone admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentWithPhoneId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Female', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Absent Kid No Contact');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Absent Kid No Contact admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentNoContactId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: enrolWithPhone, error: e1 } = await admin.from('enrolment').select('id').eq('student_id', studentWithPhoneId!).single();
  if (e1 || !enrolWithPhone) throw e1 ?? new Error('enrolment not found');
  const { data: enrolNoContact, error: e2 } = await admin.from('enrolment').select('id').eq('student_id', studentNoContactId!).single();
  if (e2 || !enrolNoContact) throw e2 ?? new Error('enrolment not found');

  const { data: guardian, error: e3 } = await admin
    .from('guardian')
    .insert({ tenant_id: tenantId, name_en: 'E2E Guardian', phone_e164: '+923001112222' })
    .select('id')
    .single();
  if (e3 || !guardian) throw e3 ?? new Error('guardian insert failed');
  const { error: e4 } = await admin
    .from('student_guardian')
    .insert({ tenant_id: tenantId, student_id: studentWithPhoneId!, guardian_id: guardian.id, relationship: 'father', is_primary: true, receives_billing: true });
  if (e4) throw e4;

  // Direct-seeded attendance_day, same reasoning as the other attendance
  // specs: this spec is about the dispatch/UI layer, not the register
  // itself. Both students absent today.
  const today = new Date().toISOString().slice(0, 10);
  const { error: e5 } = await admin.from('attendance_day').insert([
    {
      tenant_id: tenantId,
      campus_id: campusId,
      session_id: sessionId,
      section_id: sectionId,
      enrolment_id: enrolWithPhone.id,
      attendance_date: today,
      status: 'absent',
      source: 'web',
    },
    {
      tenant_id: tenantId,
      campus_id: campusId,
      session_id: sessionId,
      section_id: sectionId,
      enrolment_id: enrolNoContact.id,
      attendance_date: today,
      status: 'absent',
      source: 'web',
    },
  ]);
  if (e5) throw e5;

  await page.goto('/attendance/absentee-notifications');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('absentee-date').fill(today);
  await page.getByTestId('absentee-load').click();
  await expect(page.getByText('No notifications for this date yet.')).toBeVisible();

  await page.getByTestId('absentee-dispatch').click();
  await expect(page.getByText('Queued 1, skipped 1 (no contact).')).toBeVisible();

  await expect(page.getByTestId(`absentee-status-${enrolWithPhone.id}`)).toHaveText('queued');
  await expect(page.getByTestId(`absentee-status-${enrolNoContact.id}`)).toHaveText('skipped_no_contact');
  await expect(page.getByTestId('absentee-exceptions')).toContainText('Absent Kid No Contact');

  // Re-running the same date is a no-op (AC3) — same counts, no new rows.
  await page.getByTestId('absentee-dispatch').click();
  await expect(page.getByText('Queued 0, skipped 0 (no contact).')).toBeVisible();
});
