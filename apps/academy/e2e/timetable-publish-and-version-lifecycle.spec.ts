import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@publish-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `publish-e2e-${runId}`,
    p_legal_name: `Publish E2E School ${runId}`,
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

  const teacherEmail = `teacher-${runId}@publish-e2e.test`;
  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Physics Teacher' });
  if (e5) throw e5;

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
  // AC (F09): 2 periods a week required, only 1 will be scheduled below —
  // the deliberate shortfall this spec's own publish flow must catch.
  const { error: e8 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics.id, weekly_periods: 2 });
  if (e8) throw e8;

  const { error: e9 } = await admin
    .from('staff_teachable_subject')
    .insert({ tenant_id: tenantId as string, staff_id: teacherUser.user.id, subject_id: physics.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id });
  if (e9) throw e9;

  const { data: bellTemplate, error: e10 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e10 || !bellTemplate) throw e10 ?? new Error('bell template creation failed');
  const { error: e11 } = await admin
    .from('bell_period')
    .insert({ bell_template_id: bellTemplate.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' });
  if (e11) throw e11;

  const { data: version, error: e12 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Term 1', version_no: 1 })
    .select('id')
    .single();
  if (e12 || !version) throw e12 ?? new Error('timetable version creation failed');

  const { error: e13 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    timetable_version_id: version.id,
    section_id: section.id,
    weekday: 1,
    period_no: 1,
    subject_id: physics.id,
    staff_id: teacherUser.user.id,
  });
  if (e13) throw e13;

  return { ownerEmail, password, versionId: version.id as string, sectionId: section.id as string };
}

test('an owner is blocked from publishing a short timetable, overrides it, then clones a revision', async ({ page }) => {
  const { ownerEmail, password, versionId, sectionId } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionId}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('version-info')).toContainText('Version 1');
  await expect(page.getByTestId('version-info')).toContainText('DRAFT');

  // AC (F09): a genuine shortfall (Physics 1/2) blocks the publish and
  // names it, with no way to force it through except a real reason.
  await page.getByTestId('publish-effective-from-input').fill('2026-08-10');
  await page.getByTestId('publish-button').click();
  await expect(page.getByText("This timetable doesn't yet deliver every subject's required periods.")).toBeVisible();
  await expect(page.getByTestId('quota-shortfall-message')).toContainText('A PHY 1/2');
  await expect(page.getByTestId('version-info')).toContainText('DRAFT');

  await page.getByTestId('publish-override-reason-input').fill('temporary vacancy, second teacher joins next week');
  await page.getByTestId('publish-button').click();
  await expect(page.getByText('Timetable published.')).toBeVisible();
  await expect(page.getByTestId('version-info')).toContainText('PUBLISHED');
  await expect(page.getByTestId('version-info')).toContainText('effective 2026-08-10');
  // The one scheduled Physics period is staffed, so there's nothing to warn about.
  await expect(page.getByTestId('version-info')).toContainText('0 warning(s)');

  // AC1: a genuinely Published version's grid is read-only — no write form.
  await expect(page.getByTestId('version-immutable-banner')).toBeVisible();
  await expect(page.getByTestId('write-slot-form')).not.toBeVisible();

  // AC (F10): cloning opens a fresh, editable Draft revision.
  await page.getByTestId('clone-version-button').click();
  await expect(page.getByText('Cloned as a new draft.')).toBeVisible();
  await expect(page.getByTestId('version-info')).toContainText('Version 2');
  await expect(page.getByTestId('version-info')).toContainText('DRAFT');
  await expect(page.getByTestId('write-slot-form')).toBeVisible();

  // The clone carried over the original's own Physics period 1 slot.
  const cell = page.getByTestId('grid-cell-1-1');
  await expect(cell).toContainText('PHY');
});
