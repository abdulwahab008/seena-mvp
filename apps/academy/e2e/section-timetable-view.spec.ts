import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@section-tt-e2e.test`;
  const guardianEmail = `guardian-${runId}@section-tt-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `section-tt-e2e-${runId}`,
    p_legal_name: `Section TT E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({
    email: `teacher-${runId}@section-tt-e2e.test`,
    password,
    email_confirm: true,
  });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Physics Teacher' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: section, error: e6 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id')
    .single();
  if (e6 || !section) throw e6 ?? new Error('section creation failed');

  const { data: physics, error: e7 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e7 || !physics) throw e7 ?? new Error('subject creation failed');

  const { data: room, error: e8 } = await admin
    .from('room')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, code: 'R1', name: 'Room 1', room_type: 'CLASSROOM', capacity: 30 })
    .select('id')
    .single();
  if (e8 || !room) throw e8 ?? new Error('room creation failed');

  const guardianPhone = '923' + String(Math.floor(100000000 + Math.random() * 899999999));
  const { data: guardianUser, error: e9 } = await admin.auth.admin.createUser({
    email: guardianEmail,
    password,
    phone: guardianPhone,
    email_confirm: true,
    phone_confirm: true,
  });
  if (e9 || !guardianUser.user) throw e9 ?? new Error('guardian creation failed');

  return {
    ownerEmail,
    guardianEmail,
    password,
    tenantId: tenantId as string,
    campusId: campus!.id,
    sessionId: session!.id,
    sectionId: section.id as string,
    physicsId: physics.id as string,
    roomId: room.id as string,
    teacherUserId: teacherUser.user.id,
    guardianAuthUserId: guardianUser.user.id,
    guardianPhone,
  };
}

test('a parent sees their child\'s Published timetable, and a Draft revision stays invisible', async ({ page }) => {
  const { ownerEmail, guardianEmail, password, tenantId, campusId, sessionId, sectionId, physicsId, roomId, teacherUserId, guardianAuthUserId, guardianPhone } =
    await seedTenant();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  // Admit and enrol through the real UI as the owner, matching the
  // established "the enrolment trigger needs a real JWT" workaround.
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
  await page.getByLabel('Name', { exact: true }).fill('Section TT E2E Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Section TT E2E Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  const { data: guardian, error: eg } = await admin
    .from('guardian')
    .insert({ tenant_id: tenantId, name_en: 'Section TT E2E Guardian', phone_e164: `+${guardianPhone}`, auth_user_id: guardianAuthUserId })
    .select('id')
    .single();
  if (eg) throw eg;
  const { error: el } = await admin
    .from('student_guardian')
    .insert({ tenant_id: tenantId, student_id: studentId, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });
  if (el) throw el;

  // A Published version with a real slot, and a Draft revision with its
  // own — the Published/Draft split this whole spec is testing.
  const { data: publishedVersion, error: ev1 } = await admin
    .from('timetable_version')
    .insert({
      tenant_id: tenantId,
      campus_id: campusId,
      session_id: sessionId,
      shift: 'MORNING',
      name: 'Published v1',
      status: 'PUBLISHED',
      version_no: 1,
      effective_from: '2026-01-01',
    })
    .select('id')
    .single();
  if (ev1 || !publishedVersion) throw ev1 ?? new Error('published version creation failed');
  const { data: draftVersion, error: ev2 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId, campus_id: campusId, session_id: sessionId, shift: 'MORNING', name: 'Draft v2', status: 'DRAFT', version_no: 2 })
    .select('id')
    .single();
  if (ev2 || !draftVersion) throw ev2 ?? new Error('draft version creation failed');

  const { error: es1 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId,
    campus_id: campusId,
    timetable_version_id: publishedVersion.id,
    section_id: sectionId,
    weekday: 1,
    period_no: 1,
    subject_id: physicsId,
    staff_id: teacherUserId,
    room_id: roomId,
  });
  if (es1) throw es1;
  const { error: es2 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId,
    campus_id: campusId,
    timetable_version_id: draftVersion.id,
    section_id: sectionId,
    weekday: 1,
    period_no: 2,
    subject_id: physicsId,
    staff_id: teacherUserId,
    room_id: roomId,
  });
  if (es2) throw es2;

  // The parent, signing in for the first time in this spec, opens the
  // portal timetable.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(guardianEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/portal/timetable');
  await page.waitForLoadState('networkidle');

  // AC: the Published slot renders with subject, teacher and room.
  const publishedCell = page.getByTestId('portal-grid-cell-1-1');
  await expect(publishedCell).toContainText('Physics');
  await expect(publishedCell).toContainText('Physics Teacher');
  await expect(publishedCell).toContainText('R1');

  // AC: the Draft revision's own slot never reaches the parent, even
  // though it's the exact same section/weekday, just a different period —
  // it doesn't even show up as a period row in the grid at all, since the
  // only source of period rows here is what the Parent can actually see.
  await expect(page.getByTestId('portal-grid-cell-1-2')).toHaveCount(0);
});
