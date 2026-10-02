import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A06: session rollover and promotion engine, exercised end to end
// through the real UI — start a rollover, override two students (retain,
// pass out), drive the run to completion, and confirm the summary counts
// and the exception list. A second start against the same session pair
// then proves the AC2 no-op behaviour through the UI too.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

async function seedOwnerWithPromotionCohort() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@promotion-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `promotion-e2e-${runId}`,
    p_legal_name: `Promotion E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus, error: eCampus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  if (eCampus || !campus) throw eCampus ?? new Error('campus not seeded');
  const { data: fromSession, error: eFromSession } = await admin
    .from('academic_session')
    .select('id, name')
    .eq('tenant_id', tenantId as string)
    .single();
  if (eFromSession || !fromSession) throw eFromSession ?? new Error('session not seeded');
  const { data: class9, error: eClass9 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '9')
    .single();
  if (eClass9 || !class9) throw eClass9 ?? new Error('class 9 not seeded');
  const { data: class10, error: eClass10 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '10')
    .single();
  if (eClass10 || !class10) throw eClass10 ?? new Error('class 10 not seeded');

  const nextYearStart = new Date();
  nextYearStart.setFullYear(nextYearStart.getFullYear() + 1);
  const nextYearEnd = new Date(nextYearStart);
  nextYearEnd.setFullYear(nextYearEnd.getFullYear() + 1);
  nextYearEnd.setDate(nextYearEnd.getDate() - 1);
  const { data: toSession, error: eToSession } = await admin
    .from('academic_session')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus.id,
      name: 'Next Session',
      starts_on: nextYearStart.toISOString().slice(0, 10),
      ends_on: nextYearEnd.toISOString().slice(0, 10),
    })
    .select('id, name')
    .single();
  if (eToSession || !toSession) throw eToSession ?? new Error('to-session creation failed');

  // Seeded directly (not via create_section/create_student/enrol_student's
  // own RPCs), same as academic-structure-rollover.spec.ts: those RPCs read
  // JWT role/campus claims a service-role call never carries.
  const { data: fromSection, error: eFromSection } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus.id, session_id: fromSession.id, class_level_id: class9.id, name: 'A', capacity: 40 })
    .select('id')
    .single();
  if (eFromSection || !fromSection) throw eFromSection ?? new Error('from-section creation failed');
  const { error: eToSection } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus.id, session_id: toSession.id, class_level_id: class10.id, name: 'A', capacity: 40 });
  if (eToSection) throw eToSection;
  // Retain also needs a class-9 section in the target session.
  const { error: eToSectionSameClass } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus.id, session_id: toSession.id, class_level_id: class9.id, name: 'A', capacity: 40 });
  if (eToSectionSameClass) throw eToSectionSameClass;

  // Students and their enrolments go through create_student()/enrol_student()
  // under the owner's OWN authenticated session, not a raw service-role
  // insert: enrolment has an AFTER INSERT trigger (enrolment_ai_build_fee_plan,
  // FR-K04) that calls build_fee_plan(), which looks the new row up by
  // `tenant_id = app.auth_tenant_id()` — a service-role request carries no
  // user JWT, so that lookup (and the whole insert) fails with
  // ENROLMENT_NOT_FOUND. Signing in for real and calling the RPCs is the
  // same "seed non-UI-exposed state through a signed-in client" convention
  // homework-load-cap.spec.ts and section-double-booking-prevention.spec.ts
  // already use.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email, password });
  if (signInError) throw signInError;

  const students = ['Ayaan Malik', 'Zoya Sheikh', 'Hamza Iqbal'] as const;
  for (const name of students) {
    const { data: studentId, error: eStudent } = await ownerClient.rpc('create_student', {
      p_campus_id: campus.id,
      p_name_en: name,
      p_dob: '2014-01-01',
      p_gender: 'male',
    });
    if (eStudent || !studentId) throw eStudent ?? new Error('student creation failed');
    const { error: eEnrol } = await ownerClient.rpc('enrol_student', { p_section_id: fromSection.id, p_student_id: studentId as string });
    if (eEnrol) throw eEnrol;
  }

  return { email, password, fromSessionName: fromSession.name as string, toSessionName: toSession.name as string, students };
}

test('an owner reviews the decision list, overrides two students, and drives a rollover to completion', async ({ page }) => {
  const { email, password, fromSessionName, toSessionName, students } = await seedOwnerWithPromotionCohort();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students/promotion');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('promotion-campus-trigger').click();
  await page.getByRole('option').first().click();
  await page.getByTestId('promotion-from-session-trigger').click();
  await page.getByRole('option', { name: fromSessionName, exact: true }).click();
  await page.getByTestId('promotion-to-session-trigger').click();
  await page.getByRole('option', { name: toSessionName, exact: true }).click();

  await page.getByTestId('promotion-start-button').click();
  await expect(page.getByTestId('promotion-summary')).toBeVisible();
  // Starting only snapshots the decision set — nothing is processed until
  // the run is driven, so the progress line reads 0 of 3 here.
  await expect(page.getByText('0 of 3 processed')).toBeVisible();

  // All three default to 'promote' — every row's decision list entry
  // starts visible and editable before the run is driven.
  const rows = page.locator('tbody tr[data-testid^="promotion-decision-row-"]');
  await expect(rows).toHaveCount(3);

  // Override student 2 to retain, student 3 to pass out — student 1 stays
  // the default promote.
  const student2Row = page.locator(`tr:has-text("${students[1]}")`);
  await student2Row.locator('select').selectOption('retain');

  const student3Row = page.locator(`tr:has-text("${students[2]}")`);
  await student3Row.locator('select').selectOption('pass_out');

  // Give the override RPCs a beat to land and the list to refresh.
  await expect(student2Row.locator('select')).toHaveValue('retain');
  await expect(student3Row.locator('select')).toHaveValue('pass_out');

  await page.getByTestId('promotion-run-button').click();
  await expect(page.getByTestId('promotion-status')).toHaveText('completed', { timeout: 20_000 });

  await expect(page.getByTestId('promotion-promoted-count')).toHaveText('1');
  await expect(page.getByTestId('promotion-retained-count')).toHaveText('1');
  await expect(page.getByTestId('promotion-passed-out-count')).toHaveText('1');
  await expect(page.getByTestId('promotion-held-count')).toHaveText('0');
  await expect(page.getByTestId('promotion-exception-list')).toHaveCount(0);

  // AC2, through the UI: starting the exact same rollover again is a no-op.
  // The passed-out student is no longer eligible, so the second run's scope
  // is the 2 students who now already have an enrolment in the new session.
  await page.getByTestId('promotion-start-button').click();
  await expect(page.getByText('0 of 2 processed')).toBeVisible();
  await page.getByTestId('promotion-run-button').click();
  await expect(page.getByTestId('promotion-status')).toHaveText('completed', { timeout: 20_000 });
  await expect(page.getByTestId('promotion-created-count')).toHaveText('0');
  await expect(page.getByText(/no-op/)).toBeVisible();
});
