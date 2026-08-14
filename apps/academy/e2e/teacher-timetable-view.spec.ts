import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// A fixed week, never "today" — every slot's weekday is derived from this
// same reference date (and +1/+2 day offsets, still inside the same
// Monday-Saturday week), so the seeded data and the `?week=` URL param
// always agree on which calendar week they mean.
const REF_DATE = '2026-08-03';
const WEEKDAY_A = new Date(`${REF_DATE}T00:00:00Z`).getUTCDay();
const REF_DATE_B = new Date(`${REF_DATE}T00:00:00Z`);
REF_DATE_B.setUTCDate(REF_DATE_B.getUTCDate() + 1);
const WEEKDAY_B = REF_DATE_B.getUTCDay();
const REF_DATE_SUB = new Date(`${REF_DATE}T00:00:00Z`);
REF_DATE_SUB.setUTCDate(REF_DATE_SUB.getUTCDate() + 2);
const WEEKDAY_SUB = REF_DATE_SUB.getUTCDay();
const REF_DATE_SUB_STR = REF_DATE_SUB.toISOString().slice(0, 10);

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@teachertt-e2e.test`;
  const ayeshaEmail = `ayesha-${runId}@teachertt-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `teachertt-e2e-${runId}`,
    p_legal_name: `Teacher TT E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: ayeshaUser, error: e4 } = await admin.auth.admin.createUser({ email: ayeshaEmail, password, email_confirm: true });
  if (e4 || !ayeshaUser.user) throw e4 ?? new Error('ayesha creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: ayeshaUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Ms Ayesha' });
  if (e5) throw e5;

  const { data: absentUser, error: e6 } = await admin.auth.admin.createUser({
    email: `absent-${runId}@teachertt-e2e.test`,
    password,
    email_confirm: true,
  });
  if (e6 || !absentUser.user) throw e6 ?? new Error('absent teacher creation failed');
  const { error: e7 } = await admin
    .from('app_user')
    .insert({ user_id: absentUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Mr Absent' });
  if (e7) throw e7;

  const { data: campusA } = await admin.from('campus').select('id, code').eq('tenant_id', tenantId as string).single();
  const { data: campusB, error: e8 } = await admin
    .from('campus')
    .insert({ tenant_id: tenantId as string, name: 'Campus South', code: 'SOUTH' })
    .select('id, code')
    .single();
  if (e8 || !campusB) throw e8 ?? new Error('campus B creation failed');

  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: sectionA, error: e9 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campusA!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id, name')
    .single();
  if (e9 || !sectionA) throw e9 ?? new Error('section A creation failed');
  const { data: sectionB, error: e10 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campusB.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'B', capacity: 30 })
    .select('id, name')
    .single();
  if (e10 || !sectionB) throw e10 ?? new Error('section B creation failed');

  const { data: physics, error: e11 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e11 || !physics) throw e11 ?? new Error('subject creation failed');
  const { error: e12 } = await admin
    .from('class_subject')
    .insert([
      { tenant_id: tenantId as string, campus_id: campusA!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics.id, weekly_periods: 2 },
      { tenant_id: tenantId as string, campus_id: campusB.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics.id, weekly_periods: 1 },
    ]);
  if (e12) throw e12;

  const { data: templateA, error: e13 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campusA!.id, shift: 'MORNING', code: 'REGULAR', name: 'North Regular', is_default: true })
    .select('id')
    .single();
  if (e13 || !templateA) throw e13 ?? new Error('template A creation failed');
  const { error: e14 } = await admin
    .from('bell_period')
    .insert({ bell_template_id: templateA.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' });
  if (e14) throw e14;

  const { data: templateB, error: e15 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campusB.id, shift: 'MORNING', code: 'REGULAR', name: 'South Regular', is_default: true })
    .select('id')
    .single();
  if (e15 || !templateB) throw e15 ?? new Error('template B creation failed');
  const { error: e16 } = await admin
    .from('bell_period')
    .insert({ bell_template_id: templateB.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '09:00', end_time: '09:40' });
  if (e16) throw e16;

  const { data: versionA, error: e17 } = await admin
    .from('timetable_version')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campusA!.id,
      session_id: session!.id,
      shift: 'MORNING',
      name: 'North v1',
      status: 'PUBLISHED',
      version_no: 1,
      effective_from: '2026-01-01',
    })
    .select('id')
    .single();
  if (e17 || !versionA) throw e17 ?? new Error('version A creation failed');
  const { data: versionB, error: e18 } = await admin
    .from('timetable_version')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campusB.id,
      session_id: session!.id,
      shift: 'MORNING',
      name: 'South v1',
      status: 'PUBLISHED',
      version_no: 1,
      effective_from: '2026-01-01',
    })
    .select('id')
    .single();
  if (e18 || !versionB) throw e18 ?? new Error('version B creation failed');

  const { error: e19 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId as string,
    campus_id: campusA!.id,
    timetable_version_id: versionA.id,
    section_id: sectionA.id,
    weekday: WEEKDAY_A,
    period_no: 1,
    subject_id: physics.id,
    staff_id: ayeshaUser.user.id,
  });
  if (e19) throw e19;
  const { error: e20 } = await admin.from('timetable_slot').insert({
    tenant_id: tenantId as string,
    campus_id: campusB.id,
    timetable_version_id: versionB.id,
    section_id: sectionB.id,
    weekday: WEEKDAY_B,
    period_no: 1,
    subject_id: physics.id,
    staff_id: ayeshaUser.user.id,
  });
  if (e20) throw e20;
  const { data: slotSub, error: e21 } = await admin
    .from('timetable_slot')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campusA!.id,
      timetable_version_id: versionA.id,
      section_id: sectionA.id,
      weekday: WEEKDAY_SUB,
      period_no: 1,
      subject_id: physics.id,
      staff_id: absentUser.user.id,
    })
    .select('id')
    .single();
  if (e21 || !slotSub) throw e21 ?? new Error('substitution source slot creation failed');

  const { error: e22 } = await admin
    .from('timetable_substitution')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campusA!.id,
      slot_id: slotSub.id,
      sub_date: REF_DATE_SUB_STR,
      absent_staff_id: absentUser.user.id,
      substitute_staff_id: ayeshaUser.user.id,
      reason: 'other',
      status: 'active',
    });
  if (e22) throw e22;

  return { ownerEmail, ayeshaEmail, password, campusACode: campusA!.code, campusBCode: campusB.code };
}

test('a teacher sees her own cross-campus week with resolved times and today\'s substitution coverage', async ({ page }) => {
  const { ayeshaEmail, password, campusACode, campusBCode } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ayeshaEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto(`/my-timetable?week=${REF_DATE}`);
  await page.waitForLoadState('networkidle');

  // AC1/cross-campus: campus A and campus B both appear in the SAME
  // weekly view, each resolving its own campus's real bell time.
  const cellA = page.getByTestId(`my-timetable-cell-${WEEKDAY_A}-1`);
  await expect(cellA).toContainText('Physics');
  await expect(cellA).toContainText(campusACode);
  await expect(cellA).toContainText('08:00');

  const cellB = page.getByTestId(`my-timetable-cell-${WEEKDAY_B}-1`);
  await expect(cellB).toContainText('Physics');
  await expect(cellB).toContainText(campusBCode);
  await expect(cellB).toContainText('09:00');

  // AC3: this week's substitution coverage surfaces distinctly, above
  // (visually separate from) the regular grid, naming who she is
  // covering for.
  const subBanner = page.getByTestId(`substitution-${REF_DATE_SUB_STR}-1`);
  await expect(subBanner).toBeVisible();
  await expect(subBanner).toContainText('Mr Absent');
  await expect(subBanner).toContainText('Physics');

  // The regular grid itself never renders that same period a second time
  // — it only ever shows her OWN periods, not the one she's covering.
  await expect(page.getByTestId(`my-timetable-cell-${WEEKDAY_SUB}-1`)).toContainText('Free');
});
