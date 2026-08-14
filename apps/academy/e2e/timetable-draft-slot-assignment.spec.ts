import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@timetable-e2e.test`;
  const owner2Email = `owner2-${runId}@timetable-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `timetable-e2e-${runId}`,
    p_legal_name: `Timetable E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // A second principal-tier account, so the realtime AC can be proven
  // between two independent builders editing the same draft.
  const { data: owner2User, error: e4 } = await admin.auth.admin.createUser({ email: owner2Email, password, email_confirm: true });
  if (e4 || !owner2User.user) throw e4 ?? new Error('second owner creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: owner2User.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Co-Builder' });
  if (e5) throw e5;

  // The actual teacher being scheduled — deliberately NOT one of the
  // principal-tier accounts building the timetable, so the staff <select>
  // (scoped to teaching roles only) and the prefill both exercise a real
  // teacher record rather than accidentally matching a builder's own id.
  const teacherEmail = `teacher-${runId}@timetable-e2e.test`;
  const { data: teacherUser, error: e4b } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4b || !teacherUser.user) throw e4b ?? new Error('teacher creation failed');
  const { error: e5b } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Physics Teacher' });
  if (e5b) throw e5b;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: section, error: e6 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id')
    .single();
  if (e6) throw e6;

  const { data: physics, error: e7 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e7) throw e7;
  // Urdu deliberately never gets a class_subject row — the
  // SUBJECT_NOT_OFFERED case.
  const { error: e8 } = await admin.from('subject').insert({ tenant_id: tenantId as string, code: 'URD', name_en: 'Urdu', name_ur: 'اردو' });
  if (e8) throw e8;

  const { error: e9 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics!.id, weekly_periods: 5 });
  if (e9) throw e9;

  const { data: room, error: e10 } = await admin
    .from('room')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, code: 'R1', name: 'Room 1', room_type: 'CLASSROOM', capacity: 30 })
    .select('id')
    .single();
  if (e10) throw e10;
  const { error: e11 } = await admin.from('class_section').update({ home_room_id: room!.id }).eq('id', section!.id);
  if (e11) throw e11;

  const { error: e12 } = await admin.from('section_subject_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    subject_id: physics!.id,
    staff_id: teacherUser.user.id,
    role: 'primary',
    effective_from: new Date(Date.now() - 30 * 86400000).toISOString().slice(0, 10),
  });
  if (e12) throw e12;

  // FR-D03: upsert_timetable_slot() now also checks teach-scope — without
  // this grant every staffed write below would fail TEACH_SCOPE_VIOLATION.
  const { error: e13 } = await admin
    .from('staff_teachable_subject')
    .insert({ tenant_id: tenantId as string, staff_id: teacherUser.user.id, subject_id: physics!.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id });
  if (e13) throw e13;

  return { ownerEmail, owner2Email, password };
}

test('an owner builds a draft timetable slot with prefill, sees SUBJECT_NOT_OFFERED and clear, and a co-builder sees it live', async ({ page, browser }) => {
  const { ownerEmail, owner2Email, password } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/academic-setup/timetable');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Name').fill('Draft v1');
  await page.getByTestId('create-version-button').click();
  await expect(page.getByText('Draft v1 created.')).toBeVisible();
  await page.waitForLoadState('networkidle');

  // AC: choosing Physics pre-fills the section's primary teacher and home
  // room, both still overridable (left as-is here).
  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Physics (PHY)' }).click();
  await expect(page.getByTestId('slot-staff-trigger')).toContainText('Physics Teacher');
  await expect(page.getByTestId('slot-room-trigger')).toContainText('Room 1 (R1)');

  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Monday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('3');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.')).toBeVisible();

  const cell = page.getByTestId('grid-cell-1-3');
  await expect(cell).toContainText('PHY');
  await expect(cell).toContainText('R1');

  // AC: a subject absent from the class-subject map is rejected.
  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Urdu (URD)' }).click();
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Tuesday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('This subject is not on the curriculum map for this class level/stream.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-2-1')).toContainText('Free');

  // Co-builder, in a separate context, opens the same version and waits
  // for its realtime channel to actually be joined before the owner's
  // next write — otherwise the assertion below could race ahead of the
  // subscription.
  const coBuilderContext = await browser.newContext();
  const coBuilderPage = await coBuilderContext.newPage();
  await coBuilderPage.goto('/login');
  await coBuilderPage.waitForLoadState('networkidle');
  await coBuilderPage.getByLabel('Email').fill(owner2Email);
  await coBuilderPage.getByLabel('Password').fill(password);
  await coBuilderPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(coBuilderPage).toHaveURL(/\/dashboard$/);

  await coBuilderPage.goto('/academic-setup/timetable');
  await coBuilderPage.waitForLoadState('networkidle');
  await expect(coBuilderPage.getByTestId('timetable-realtime-status')).toHaveAttribute('data-status', 'SUBSCRIBED');
  await expect(coBuilderPage.getByTestId('grid-cell-4-2')).toContainText('Free');

  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Physics (PHY)' }).click();
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Thursday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('2');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.')).toBeVisible();

  // AC: the co-builder's grid reflects the write live, no reload.
  await expect(coBuilderPage.getByTestId('grid-cell-4-2')).toContainText('PHY', { timeout: 10000 });

  // AC: clearing a slot deletes the row — the cell renders free again,
  // and this too propagates live to the co-builder.
  await page.getByTestId('clear-slot-1-3').click();
  await expect(page.getByText('Slot cleared.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-3')).toContainText('Free');
  await expect(coBuilderPage.getByTestId('grid-cell-1-3')).toContainText('Free', { timeout: 10000 });
});
