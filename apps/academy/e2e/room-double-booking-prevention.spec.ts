import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// Radix's Select keeps cleaning up (pointer-events/focus-trap teardown)
// for a beat after its listbox unmounts — clicking a DIFFERENT trigger
// too soon after closing one can silently swallow that click outright
// (confirmed by instrumenting the app: the click never reaches the
// trigger's own handler). Waiting for the listbox to unmount isn't
// enough on its own; the trailing wait is what actually makes this
// reliable across repeated runs.
async function selectOption(page: Page, triggerTestId: string, optionName: string, exact = false) {
  await page.getByTestId(triggerTestId).click();
  await page.getByRole('option', { name: optionName, exact }).click();
  await page.getByRole('listbox').waitFor({ state: 'hidden' });
  await page.waitForTimeout(300);
}

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@room-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `room-e2e-${runId}`,
    p_legal_name: `Room E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const teacherAEmail = `teacher-a-${runId}@room-e2e.test`;
  const { data: teacherAUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherAEmail, password, email_confirm: true });
  if (e4 || !teacherAUser.user) throw e4 ?? new Error('teacher a creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherAUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Teacher A' });
  if (e5) throw e5;

  const teacherBEmail = `teacher-b-${runId}@room-e2e.test`;
  const { data: teacherBUser, error: e6 } = await admin.auth.admin.createUser({ email: teacherBEmail, password, email_confirm: true });
  if (e6 || !teacherBUser.user) throw e6 ?? new Error('teacher b creation failed');
  const { error: e7 } = await admin
    .from('app_user')
    .insert({ user_id: teacherBUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Teacher B' });
  if (e7) throw e7;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: sectionA, error: e8 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 40 })
    .select('id')
    .single();
  if (e8 || !sectionA) throw e8 ?? new Error('section a creation failed');
  const { data: sectionB, error: e9 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'B', capacity: 40 })
    .select('id')
    .single();
  if (e9 || !sectionB) throw e9 ?? new Error('section b creation failed');

  const { data: islamiyat, error: e10 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'ISL', name_en: 'Islamiyat', name_ur: 'اسلامیات' })
    .select('id')
    .single();
  if (e10 || !islamiyat) throw e10 ?? new Error('islamiyat subject creation failed');
  const { data: physics, error: e11 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e11 || !physics) throw e11 ?? new Error('physics subject creation failed');
  const { error: e12 } = await admin.from('class_subject').insert([
    { tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: islamiyat.id, weekly_periods: 1 },
    { tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics.id, weekly_periods: 1 },
  ]);
  if (e12) throw e12;

  const { error: e13 } = await admin.from('staff_teachable_subject').insert([
    { tenant_id: tenantId as string, staff_id: teacherAUser.user.id, subject_id: islamiyat.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
    { tenant_id: tenantId as string, staff_id: teacherAUser.user.id, subject_id: physics.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
    { tenant_id: tenantId as string, staff_id: teacherBUser.user.id, subject_id: islamiyat.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
    { tenant_id: tenantId as string, staff_id: teacherBUser.user.id, subject_id: physics.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
  ]);
  if (e13) throw e13;

  // Deliberately smaller than the two sections' combined 40+40 — the
  // overflow this spec's own AC4 assertion needs to actually trigger.
  const { data: hall, error: e14 } = await admin
    .from('room')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, code: 'HALL', name: 'The Hall', room_type: 'CLASSROOM', capacity: 50 })
    .select('id')
    .single();
  if (e14 || !hall) throw e14 ?? new Error('hall creation failed');

  const { data: bellTemplate, error: e15 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e15 || !bellTemplate) throw e15 ?? new Error('bell template creation failed');
  const { error: e16 } = await admin
    .from('bell_period')
    .insert({ bell_template_id: bellTemplate.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' });
  if (e16) throw e16;

  const { data: version, error: e17 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Draft v1', version_no: 1 })
    .select('id')
    .single();
  if (e17 || !version) throw e17 ?? new Error('version creation failed');

  return { ownerEmail, password, versionId: version.id as string, sectionAId: sectionA.id as string, sectionBId: sectionB.id as string };
}

test('a different subject clashes with an occupied room, but the same subject combines two sections and an overflow warns without blocking', async ({ page }) => {
  const { ownerEmail, password, versionId, sectionAId, sectionBId } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Section A books Islamiyat in the Hall.
  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionAId}`);
  await page.waitForLoadState('networkidle');

  await selectOption(page, 'slot-subject-trigger', 'Islamiyat (ISL)');
  await selectOption(page, 'slot-room-trigger', 'The Hall (HALL)');
  await selectOption(page, 'slot-weekday-trigger', 'Monday', true);
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.').last()).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('ISL');

  // AC1: section B tries a DIFFERENT subject in the same room at the same
  // time — rejected, naming section A and the clash time.
  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionBId}`);
  await page.waitForLoadState('networkidle');

  await selectOption(page, 'slot-subject-trigger', 'Physics (PHY)');
  await selectOption(page, 'slot-room-trigger', 'The Hall (HALL)');
  await selectOption(page, 'slot-weekday-trigger', 'Monday', true);
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('This room is already booked — section A at 08:00-08:40.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('Free');

  // AC2: the SAME subject for section B is a deliberate combined lecture
  // — it saves, no clash.
  await selectOption(page, 'slot-subject-trigger', 'Islamiyat (ISL)');
  await selectOption(page, 'slot-room-trigger', 'The Hall (HALL)');
  await selectOption(page, 'slot-weekday-trigger', 'Monday', true);
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.').last()).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('ISL');

  // AC4: 40 (A) + 40 (B) = 80 against the Hall's own capacity of 50 — a
  // visible warning, not a block. Visible from either section's own view,
  // since the warning is keyed to the room-cell, not one section.
  const warning = page.getByTestId('room-capacity-warning-1-1');
  await expect(warning).toBeVisible();
  await expect(warning).toContainText('80/50');

  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionAId}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('room-capacity-warning-1-1')).toContainText('80/50');
});
