import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I12: teacher mark entry with validation, through the real UI.
//
// All four acceptance criteria are statements about a screen a teacher is
// typing into, so all four are asserted on one:
//
//   AC1  70 into a theory paper out of 65 — the cell is marked invalid with
//        "max 65", nothing is persisted, and the caret does not leave.
//   AC2  45.5 at mark_precision 0 — "whole numbers only".
//   AC3  down a column on Enter alone, each value autosaved as a draft in
//        well under two seconds with no page reload.
//   AC4  offline mid-entry, then back — one batch, and exactly one row per
//        (exam_subject, enrolment, component), checked in the database
//        rather than inferred from the screen.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * Seeds a Physics teacher who is actually allocated to 9-A, the exam setup
 * AC1 is written about (theory 65 / practical 20), and three candidates.
 * Curriculum, allocation and exam setup go in without driving their own
 * screens: FR-E06, FR-E09 and FR-I02 all have their own e2e coverage, and
 * this spec is about what FR-I12 does with what they produce.
 *
 * Students, enrolments and the exam configuration go through a SIGNED-IN
 * owner rather than the service role — those RPCs read JWT role/campus
 * claims a service-role call never carries, and enrolment's fee-plan trigger
 * looks the new row up by app.auth_tenant_id(). Same reason as
 * e2e/certificate-register.spec.ts.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const email = `phy-${runId}@mark-entry-e2e.test`;
  const ownerEmail = `owner-${runId}@mark-entry-e2e.test`;
  const password = PASSWORD;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `mark-entry-e2e-${runId}`,
    p_legal_name: `Mark Entry E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (userEmail: string, role: 'owner' | 'subject_teacher', fullName: string) => {
    const { data: created, error } = await db.auth.admin.createUser({
      email: userEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    if (error || !created.user) throw error ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await db
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenant, app_role: role, full_name: fullName });
    if (appUserError) throw appUserError;
    const { error: campusError } = await db
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenant, campus_id: campus!.id });
    if (campusError) throw campusError;
    return created.user.id;
  };
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  const teacherId = await makeUser(email, 'subject_teacher', 'E2E Physics Teacher');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  const { data: class9 } = await db
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenant)
    .eq('code', '9')
    .single();

  const { data: physics } = await db
    .from('subject')
    .insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' })
    .select('id')
    .single();

  const { data: classSubject } = await db
    .from('class_subject')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      subject_id: physics!.id,
      weekly_periods: 5,
    })
    .select('id')
    .single();

  const { data: section } = await db
    .from('class_section')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      name: 'A',
      capacity: 40,
    })
    .select('id')
    .single();

  // The FR-E09 allocation that makes this teacher the one who may enter
  // these marks — without it fn_upsert_marks() refuses them.
  await db.from('section_subject_teacher').insert({
    tenant_id: tenant,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    subject_id: physics!.id,
    staff_id: teacherId,
    effective_from: new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10),
  });

  const { data: term } = await db
    .from('exam_term')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      code: 'T1',
      name: 'First Term',
      sequence: 1,
      weight_bp: 10000,
      status: 'active',
    })
    .select('id')
    .single();

  const { data: examSubjectId, error: e4 } = await ownerClient.rpc('upsert_exam_subject', {
    p_exam_term_id: term!.id,
    p_class_subject_id: classSubject!.id,
    p_components: [
      { component: 'theory', max_marks: 65, pass_marks: 23 },
      { component: 'practical', max_marks: 20, pass_marks: 7 },
    ],
  });
  if (e4) throw e4;

  const cohort = [
    { name: 'Ali Raza', dob: '2011-03-04' },
    { name: 'Zoya Sheikh', dob: '2011-07-21' },
    { name: 'Hamza Iqbal', dob: '2012-01-09' },
  ];
  for (const [i, s] of cohort.entries()) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
      p_gender: 'male',
      p_father_name_en: 'Muhammad Raza',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    const { error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    // Roll numbers are what the grid rows are addressed by; set them
    // deterministically rather than depending on allocation order.
    const { error: rollError } = await db
      .from('enrolment')
      .update({ roll_no: i + 1 })
      .eq('student_id', studentId as string);
    if (rollError) throw rollError;
  }

  return { email, password, examSubjectId: examSubjectId as string };
}

async function signIn(page: import('@playwright/test').Page, email: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function openGrid(page: import('@playwright/test').Page) {
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Physics' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
}

test('a teacher enters a column of Physics marks, is refused an over-max and a fractional one, and loses nothing when the connection drops', async ({
  page,
}) => {
  const { email, password, examSubjectId } = await seed();
  const db = admin();

  await signIn(page, email, password);
  await openGrid(page);

  await expect(page.getByTestId('mark-entry-total-max')).toHaveText('85');
  await expect(page.getByTestId('mark-entry-column-theory')).toContainText('max 65 / pass 23');
  await expect(page.getByTestId('mark-entry-column-practical')).toContainText('max 20 / pass 7');
  await expect(page.getByTestId('mark-entry-precision')).toHaveText('Whole numbers only');

  // ── AC1: 70 into a paper out of 65 ──────────────────────────────────
  const theory1 = page.getByTestId('mark-cell-1-theory');
  await theory1.click();
  await theory1.fill('70');
  await expect(page.getByTestId('mark-cell-error-1-theory')).toHaveText('max 65');
  await expect(theory1).toHaveAttribute('aria-invalid', 'true');
  // The caret has not left the cell, and Enter does not carry the mistake on.
  await theory1.press('Enter');
  await expect(theory1).toBeFocused();

  // Nothing was persisted — asserted in the database, not on the screen.
  await page.waitForTimeout(1500);
  const { count: afterInvalid } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('exam_subject_id', examSubjectId);
  expect(afterInvalid).toBe(0);

  // ── AC2: 45.5 where the campus awards whole marks ────────────────────
  await theory1.fill('45.5');
  await expect(page.getByTestId('mark-cell-error-1-theory')).toHaveText('whole numbers only');
  await page.waitForTimeout(1000);
  const { count: afterFraction } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('exam_subject_id', examSubjectId);
  expect(afterFraction).toBe(0);

  // ── AC3: down the column on Enter, autosaved as draft ────────────────
  await theory1.fill('60');
  await expect(page.getByTestId('mark-cell-error-1-theory')).toHaveCount(0);
  await theory1.press('Enter');
  await expect(page.getByTestId('mark-cell-2-theory')).toBeFocused();
  await page.getByTestId('mark-cell-2-theory').fill('55');
  await page.getByTestId('mark-cell-2-theory').press('Enter');
  await expect(page.getByTestId('mark-cell-3-theory')).toBeFocused();
  await page.getByTestId('mark-cell-3-theory').fill('50');

  // "within 2 seconds without a page reload".
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText(/^Saved/, { timeout: 2000 });
  await expect(page).toHaveURL(/\/exams\/marks$/);

  await expect
    .poll(async () => {
      const { data } = await db
        .from('mark_entry')
        .select('marks_obtained, status')
        .eq('exam_subject_id', examSubjectId)
        .eq('component_code', 'theory');
      return (data ?? []).length;
    })
    .toBe(3);
  const { data: theoryRows } = await db
    .from('mark_entry')
    .select('marks_obtained, status')
    .eq('exam_subject_id', examSubjectId)
    .eq('component_code', 'theory');
  expect(theoryRows!.every((r) => r.status === 'draft')).toBe(true);
  expect(theoryRows!.map((r) => Number(r.marks_obtained)).sort((a, b) => a - b)).toEqual([50, 55, 60]);

  // ── AC4: the connection drops mid-entry ──────────────────────────────
  await page.context().setOffline(true);
  await page.getByTestId('mark-cell-1-practical').fill('18');
  await page.getByTestId('mark-cell-2-practical').fill('17');
  await page.getByTestId('mark-cell-3-practical').fill('16');
  await expect(page.getByTestId('mark-entry-queued-count')).toHaveText('3 waiting');
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText('Offline — held for sending');

  // Nothing reached the server while the link was down.
  const { count: whileOffline } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('exam_subject_id', examSubjectId)
    .eq('component_code', 'practical');
  expect(whileOffline).toBe(0);

  await page.context().setOffline(false);
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText(/^Saved/, { timeout: 15000 });
  await expect(page.getByTestId('mark-entry-queued-count')).toHaveCount(0);

  // One batch, and exactly one row per (exam_subject, enrolment, component).
  const { data: batches } = await db.from('mark_entry_batch').select('id').eq('exam_subject_id', examSubjectId);
  expect(batches!.length).toBe(1);

  const { data: allRows } = await db
    .from('mark_entry')
    .select('enrolment_id, component_code, marks_obtained')
    .eq('exam_subject_id', examSubjectId);
  expect(allRows!.length).toBe(6);
  expect(new Set(allRows!.map((r) => `${r.enrolment_id}:${r.component_code}`)).size).toBe(6);
  expect(
    allRows!
      .filter((r) => r.component_code === 'practical')
      .map((r) => Number(r.marks_obtained))
      .sort((a, b) => a - b),
  ).toEqual([16, 17, 18]);

  // No page reload was ever needed, but one shows the marks came back from
  // the server rather than living in React state.
  await openGrid(page);
  await expect(page.getByTestId('mark-cell-1-theory')).toHaveValue('60');
  await expect(page.getByTestId('mark-cell-1-practical')).toHaveValue('18');
});

test('a teacher who does not teach the class subject gets a read-only grid', async ({ page }) => {
  const { examSubjectId } = await seed();
  const db = admin();
  const runId = randomUUID().slice(0, 8);

  // A second teacher of the same campus, allocated to nothing.
  const { data: es } = await db.from('exam_subject').select('tenant_id, campus_id').eq('id', examSubjectId).single();
  const email = `urdu-${runId}@mark-entry-e2e.test`;
  const password = 'e2e-test-password-123!';
  const { data: created } = await db.auth.admin.createUser({ email, password, email_confirm: true });
  await db
    .from('app_user')
    .insert({ user_id: created!.user!.id, tenant_id: es!.tenant_id, app_role: 'subject_teacher', full_name: 'E2E Urdu Teacher' });
  await db
    .from('user_campus')
    .insert({ user_id: created!.user!.id, tenant_id: es!.tenant_id, campus_id: es!.campus_id });

  await signIn(page, email, password);
  await openGrid(page);

  await expect(page.getByTestId('mark-entry-readonly')).toBeVisible();
  await expect(page.getByTestId('mark-cell-1-theory')).toBeDisabled();
});
