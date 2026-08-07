import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// A fixed date, never treated as "today" — its actual weekday is derived
// (never hand-picked) so the seeded timetable_slot rows and the date typed
// into the UI always agree on which weekday they represent.
const SUB_DATE = '2026-08-03';
const WEEKDAY = new Date(`${SUB_DATE}T00:00:00Z`).getUTCDay();

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@sub-e2e.test`;
  const absentEmail = `absent-${runId}@sub-e2e.test`;
  const busyEmail = `busy-${runId}@sub-e2e.test`;
  const freeEmail = `free-${runId}@sub-e2e.test`;
  const absentName = 'Ayesha Malik';
  const busyName = 'Bilal Khan';
  const freeName = 'Faiza Sheikh';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `sub-e2e-${runId}`,
    p_legal_name: `Sub E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: absentUser, error: e4 } = await admin.auth.admin.createUser({ email: absentEmail, password, email_confirm: true });
  if (e4 || !absentUser.user) throw e4 ?? new Error('absent teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: absentUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: absentName });
  if (e5) throw e5;

  const { data: busyUser, error: e6 } = await admin.auth.admin.createUser({ email: busyEmail, password, email_confirm: true });
  if (e6 || !busyUser.user) throw e6 ?? new Error('busy teacher creation failed');
  const { error: e7 } = await admin
    .from('app_user')
    .insert({ user_id: busyUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: busyName });
  if (e7) throw e7;

  const { data: freeUser, error: e8 } = await admin.auth.admin.createUser({ email: freeEmail, password, email_confirm: true });
  if (e8 || !freeUser.user) throw e8 ?? new Error('free teacher creation failed');
  const { error: e9 } = await admin
    .from('app_user')
    .insert({ user_id: freeUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: freeName });
  if (e9) throw e9;

  // AC4 needs a Module D staff record linked back to the absent teacher's
  // login, so cancel_leave_application's trigger can resolve
  // leave_application.staff_id -> app_user.user_id.
  const { data: absentStaff, error: e10 } = await admin
    .from('staff')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      user_id: absentUser.user.id,
      employee_code: 'T-0001',
      cnic: '42101-1234004-1',
      gender: 'female',
      full_name: absentName,
    })
    .select('id')
    .single();
  if (e10 || !absentStaff) throw e10 ?? new Error('staff creation failed');

  const { data: leaveType, error: e11 } = await admin
    .from('leave_type')
    .insert({ tenant_id: tenantId as string, code: 'CASUAL', name_en: 'Casual Leave', entitlement_days: 10 })
    .select('id')
    .single();
  if (e11 || !leaveType) throw e11 ?? new Error('leave type creation failed');

  const { data: sectionA, error: e12 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id, name')
    .single();
  if (e12 || !sectionA) throw e12 ?? new Error('section A creation failed');
  const { data: sectionB, error: e13 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'B', capacity: 30 })
    .select('id')
    .single();
  if (e13 || !sectionB) throw e13 ?? new Error('section B creation failed');

  const { data: physics, error: e14 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e14 || !physics) throw e14 ?? new Error('subject creation failed');
  const { error: e15 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics.id, weekly_periods: 5 });
  if (e15) throw e15;

  const { data: bellTemplate, error: e16 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e16 || !bellTemplate) throw e16 ?? new Error('bell template creation failed');
  const { error: e17 } = await admin.from('bell_period').insert([
    { bell_template_id: bellTemplate.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' },
    { bell_template_id: bellTemplate.id, segment_ordinal: 2, period_no: 2, kind: 'TEACHING', start_time: '09:00', end_time: '09:40' },
  ]);
  if (e17) throw e17;

  const { data: version, error: e18 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Draft v1' })
    .select('id')
    .single();
  if (e18 || !version) throw e18 ?? new Error('timetable version creation failed');

  // The absent teacher's own period 1 — the row the substitutions screen
  // must list as uncovered, and the row that must stay completely
  // untouched throughout this test.
  const { error: e19 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    timetable_version_id: version.id,
    section_id: sectionA.id,
    weekday: WEEKDAY,
    period_no: 1,
    subject_id: physics.id,
    staff_id: absentUser.user.id,
  });
  if (e19) throw e19;

  // The busy teacher's own period 1, in a different section but the exact
  // same clock time — AC #2's "already teaches this period" exclusion.
  const { error: e20 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    timetable_version_id: version.id,
    section_id: sectionB.id,
    weekday: WEEKDAY,
    period_no: 1,
    subject_id: physics.id,
    staff_id: busyUser.user.id,
  });
  if (e20) throw e20;

  // AC1's own trigger: the absent teacher was marked absent for this date.
  const { error: e21 } = await admin
    .from('staff_attendance')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, staff_id: absentStaff.id, att_date: SUB_DATE, status: 'absent' });
  if (e21) throw e21;

  // AC4's own precondition: an already-approved application covering the
  // substitution's date, seeded directly with status='approved' (this spec
  // is testing cancel_leave_application, not apply_for_leave/decide).
  const { data: leaveApp, error: e22 } = await admin
    .from('leave_application')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      staff_id: absentStaff.id,
      leave_type_id: leaveType.id,
      from_date: SUB_DATE,
      to_date: SUB_DATE,
      working_days: 1,
      status: 'approved',
      decided_at: new Date(0).toISOString(),
    })
    .select('id')
    .single();
  if (e22 || !leaveApp) throw e22 ?? new Error('leave application creation failed');

  return {
    ownerEmail,
    absentEmail,
    password,
    absentName,
    busyName,
    freeName,
    leaveAppId: leaveApp.id as string,
    absentSlotSectionId: sectionA.id as string,
    absentUserId: absentUser.user.id,
  };
}

test('an owner covers an absent teacher\'s period, then a cancelled leave flags it for review', async ({ page, browser }) => {
  const { ownerEmail, absentEmail, password, absentName, busyName, freeName, leaveAppId, absentSlotSectionId, absentUserId } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/substitutions');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('sub-date-input').fill(SUB_DATE);
  await page.getByTestId('sub-load-button').click();

  // AC1: the absent teacher shows up as needing coverage today.
  const absentButton = page.getByTestId(`absent-teacher-${absentName.replace(/\s+/g, '-')}`);
  await expect(absentButton).toBeVisible();
  await absentButton.click();

  // AC1: their one timetabled period that weekday is listed as uncovered.
  const periodCard = page.getByTestId('sub-period-1');
  await expect(periodCard).toBeVisible();
  await expect(page.getByTestId('sub-status-1')).toHaveText('Uncovered');

  await page.getByTestId('sub-fill-1').click();

  // AC #2: the busy teacher (their own period 1, same clock time, a
  // different section) is ranked but visibly marked busy; the free
  // teacher carries no such badge.
  const busyCandidate = page.getByTestId(`sub-candidate-${busyName.replace(/\s+/g, '-')}`);
  const freeCandidate = page.getByTestId(`sub-candidate-${freeName.replace(/\s+/g, '-')}`);
  await expect(busyCandidate).toBeVisible();
  await expect(busyCandidate).toContainText('busy');
  await expect(freeCandidate).toBeVisible();
  await expect(freeCandidate).not.toContainText('busy');

  // AC1: filled in 2 taps — the period tap above, and this candidate tap.
  await freeCandidate.click();
  await expect(page.getByText('Substitute assigned.')).toBeVisible();
  await expect(page.getByTestId('sub-status-1')).toContainText(`Covered by ${freeName}`);

  // AC (the master row itself): the original timetable_slot is never
  // touched by any of the above — still owned by the absent teacher, never
  // rewritten to the substitute.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: masterSlot } = await admin
    .from('timetable_slot')
    .select('staff_id')
    .eq('section_id', absentSlotSectionId)
    .eq('weekday', WEEKDAY)
    .eq('period_no', 1)
    .single();
  expect(masterSlot?.staff_id).toBe(absentUserId);

  // AC #4: the absent teacher, in a separate browser context, cancels
  // their own already-approved leave for this date.
  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(absentEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/campuses$/);

  await teacherPage.goto('/leave');
  await teacherPage.waitForLoadState('networkidle');
  await expect(teacherPage.getByTestId('leave-app-status-CASUAL-2026-08-03')).toHaveText('approved');
  await teacherPage.getByTestId(`leave-cancel-${leaveAppId}`).click();
  await expect(teacherPage.getByText('Application cancelled.')).toBeVisible();
  await expect(teacherPage.getByTestId('leave-app-status-CASUAL-2026-08-03')).toHaveText('cancelled');

  // AC4: the substitution built against that date is never deleted — it
  // surfaces on the review worklist instead.
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('sub-review-worklist')).toBeVisible();
  await expect(page.getByTestId('sub-review-worklist')).toContainText(absentName);
  await expect(page.getByTestId('sub-review-worklist')).toContainText(freeName);

  await page.getByTestId('sub-date-input').fill(SUB_DATE);
  await page.getByTestId('sub-load-button').click();
  await absentButton.click();
  await expect(page.getByTestId('sub-status-1')).toContainText('needs review');
});
