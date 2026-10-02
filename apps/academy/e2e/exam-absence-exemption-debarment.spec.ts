import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I11: absent, exempt and debarred handling, through the real UI.
//
//   AC1  A candidate marked Absent cannot be given marks — the cell is shut
//        and nothing is persisted.
//   AC2  A candidate Exempt from Islamiat and taking Ethics: the exemption is
//        recorded on the screen and the DENOMINATOR shrinks, checked in
//        v_exam_result_input against a classmate who sat the same paper.
//   AC3  The absent candidate scores 0 against the paper's full maximum, and
//        'AB' is what the grid shows and the result input carries.
//   AC4  Once a mark is approved the status is frozen, and the refusal that
//        reaches the screen names the break-glass path word for word.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const LOCKED =
  'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * Class 9-A sitting Maths (out of 100) and Islamiat (out of 50), with an Exam
 * Controller and a Maths teacher. Same posture as
 * e2e/teacher-mark-entry.spec.ts: students, enrolments and the exam setup go
 * through a SIGNED-IN owner, because those RPCs read JWT claims a
 * service-role call never carries and enrolment's fee-plan trigger looks the
 * new row up by app.auth_tenant_id().
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@absence-e2e.test`;
  const controllerEmail = `controller-${runId}@absence-e2e.test`;
  const teacherEmail = `maths-${runId}@absence-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `absence-e2e-${runId}`,
    p_legal_name: `Absence E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller' | 'subject_teacher', name: string) => {
    const { data: created, error } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (error || !created.user) throw error ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await db
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenant, app_role: role, full_name: name });
    if (appUserError) throw appUserError;
    const { error: campusError } = await db
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenant, campus_id: campus!.id });
    if (campusError) throw campusError;
    return created.user.id;
  };
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  await makeUser(controllerEmail, 'exam_controller', 'E2E Exam Controller');
  const teacherId = await makeUser(teacherEmail, 'subject_teacher', 'E2E Maths Teacher');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  const { data: class9 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '9').single();

  const subjectIds: Record<string, string> = {};
  for (const [code, en, ur] of [
    ['MTH', 'Mathematics', 'ریاضی'],
    ['ISL', 'Islamiat', 'اسلامیات'],
  ]) {
    const { data } = await db
      .from('subject')
      .insert({ tenant_id: tenant, code, name_en: en, name_ur: ur })
      .select('id')
      .single();
    subjectIds[en!] = data!.id;
  }

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

  const { data: term } = await db
    .from('exam_term')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      code: 'FINAL',
      name: 'Final Term',
      sequence: 1,
      weight_bp: 10000,
      status: 'active',
    })
    .select('id')
    .single();

  const examSubjectIds: Record<string, string> = {};
  for (const [name, max] of [
    ['Mathematics', 100],
    ['Islamiat', 50],
  ] as const) {
    const { data: classSubject } = await db
      .from('class_subject')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: class9!.id,
        subject_id: subjectIds[name]!,
        weekly_periods: 4,
      })
      .select('id')
      .single();
    const { data: examSubjectId, error } = await ownerClient.rpc('upsert_exam_subject', {
      p_exam_term_id: term!.id,
      p_class_subject_id: classSubject!.id,
      p_components: [{ component: 'theory', max_marks: max, pass_marks: Math.round(max / 3) }],
    });
    if (error) throw error;
    examSubjectIds[name] = examSubjectId as string;
  }

  // The Maths teacher's FR-E09 allocation, so the "a teacher may record an
  // absence but not an exemption" split has someone to be tested on.
  await db.from('section_subject_teacher').insert({
    tenant_id: tenant,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    subject_id: subjectIds['Mathematics']!,
    staff_id: teacherId,
    effective_from: new Date(Date.now() - 30 * 86400_000).toISOString().slice(0, 10),
  });

  const enrolmentIds: string[] = [];
  const cohort = [
    { name: 'Absent Ali', dob: '2011-03-04' },
    { name: 'Exempt Emma', dob: '2011-07-21' },
    { name: 'Present Piya', dob: '2012-01-09' },
  ];
  for (const [i, s] of cohort.entries()) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
      p_gender: 'female',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    const { error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    const { data: enrolment, error: rollError } = await db
      .from('enrolment')
      .update({ roll_no: i + 1 })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    if (rollError) throw rollError;
    enrolmentIds.push(enrolment!.id);
  }

  return { controllerEmail, teacherEmail, examSubjectIds, enrolmentIds };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function openGrid(page: import('@playwright/test').Page, subject: string) {
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('mark-subject-select').selectOption({ label: subject });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
}

test('an Exam Controller records an absence and an exemption, and the two compute differently', async ({ page }) => {
  const { controllerEmail, examSubjectIds, enrolmentIds } = await seed();
  const db = admin();

  await signIn(page, controllerEmail);

  // ── AC1 / AC3: Absent Ali did not sit Maths ─────────────────────────
  await openGrid(page, 'Mathematics');
  await page.getByTestId('mark-status-1').selectOption('absent');
  await expect(page.getByTestId('mark-reason-1')).toHaveValue('medical');
  await expect(page.getByTestId('mark-symbol-1')).toHaveText('AB');
  // AC1: there is no cell to type 45 into any more.
  await expect(page.getByTestId('mark-cell-1-theory')).toBeDisabled();

  await expect
    .poll(async () => {
      const { data } = await db
        .from('exam_attendance')
        .select('status, reason')
        .eq('exam_subject_id', examSubjectIds['Mathematics']!)
        .eq('enrolment_id', enrolmentIds[0]!)
        .maybeSingle();
      return data?.status ?? null;
    })
    .toBe('absent');
  const { count: absentMarks } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('enrolment_id', enrolmentIds[0]!);
  expect(absentMarks).toBe(0);

  // AC3: 0 obtained against the FULL maximum, and 'AB' on the report.
  const { data: absentInput } = await db
    .from('v_exam_result_input')
    .select('obtained_marks, denominator_marks, paper_max_marks, report_symbol, blocks_result')
    .eq('exam_subject_id', examSubjectIds['Mathematics']!)
    .eq('enrolment_id', enrolmentIds[0]!)
    .single();
  expect(Number(absentInput!.obtained_marks)).toBe(0);
  expect(absentInput!.denominator_marks).toBe(100);
  expect(absentInput!.report_symbol).toBe('AB');
  expect(absentInput!.blocks_result).toBe(false);

  // ── AC2: Exempt Emma is exempt from Islamiat ─────────────────────────
  await openGrid(page, 'Islamiat');
  await page.getByTestId('mark-status-2').selectOption('exempt');
  await expect(page.getByTestId('mark-reason-2')).toHaveValue('religious_exemption');
  await expect(page.getByTestId('mark-symbol-2')).toHaveText('EX');

  await expect
    .poll(async () => {
      const { data } = await db
        .from('v_exam_result_input')
        .select('denominator_marks')
        .eq('exam_subject_id', examSubjectIds['Islamiat']!)
        .eq('enrolment_id', enrolmentIds[1]!)
        .maybeSingle();
      return data?.denominator_marks ?? null;
    })
    // AC2: 0, not 50 — the denominator SHRANK.
    .toBe(0);

  const { data: exemptInput } = await db
    .from('v_exam_result_input')
    .select('obtained_marks, denominator_marks, paper_max_marks, report_symbol')
    .eq('exam_subject_id', examSubjectIds['Islamiat']!)
    .eq('enrolment_id', enrolmentIds[1]!)
    .single();
  expect(Number(exemptInput!.obtained_marks)).toBe(0);
  expect(exemptInput!.paper_max_marks).toBe(50);
  expect(exemptInput!.report_symbol).toBe('EX');

  // The classmate who sat the same paper is still out of the full 50 — the
  // whole distinction this FR exists for, on one screen.
  const { data: classmateInput } = await db
    .from('v_exam_result_input')
    .select('denominator_marks, report_symbol')
    .eq('exam_subject_id', examSubjectIds['Islamiat']!)
    .eq('enrolment_id', enrolmentIds[2]!)
    .single();
  expect(classmateInput!.denominator_marks).toBe(50);
  expect(classmateInput!.report_symbol).toBeNull();

  // ── AC4: an approved mark freezes the status ─────────────────────────
  await openGrid(page, 'Mathematics');
  await page.getByTestId('mark-cell-3-theory').fill('72');
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText(/^Saved/, { timeout: 5000 });

  // FR-I16 will do this; today it is the seam.
  const { error: approveError } = await db
    .from('mark_entry')
    .update({ status: 'approved' })
    .eq('exam_subject_id', examSubjectIds['Mathematics']!)
    .eq('enrolment_id', enrolmentIds[2]!);
  expect(approveError).toBeNull();

  await openGrid(page, 'Mathematics');
  await page.getByTestId('mark-status-3').selectOption('absent');
  await expect(page.getByRole('region', { name: /Notifications/ }).getByText(LOCKED)).toBeVisible();
  // The refused change is rolled back on screen, not left looking applied.
  await expect(page.getByTestId('mark-status-3')).toHaveValue('present');

  const { data: stillNone } = await db
    .from('exam_attendance')
    .select('id')
    .eq('exam_subject_id', examSubjectIds['Mathematics']!)
    .eq('enrolment_id', enrolmentIds[2]!)
    .maybeSingle();
  expect(stillNone).toBeNull();
});

test('a teacher may record an absence but cannot grant an exemption', async ({ page }) => {
  const { teacherEmail, examSubjectIds, enrolmentIds } = await seed();
  const db = admin();

  await signIn(page, teacherEmail);
  await openGrid(page, 'Mathematics');

  // The invigilator saw the empty chair; that much is theirs to record.
  await page.getByTestId('mark-status-1').selectOption('absent');
  await expect(page.getByTestId('mark-symbol-1')).toHaveText('AB');
  await expect
    .poll(async () => {
      const { data } = await db
        .from('exam_attendance')
        .select('status')
        .eq('exam_subject_id', examSubjectIds['Mathematics']!)
        .eq('enrolment_id', enrolmentIds[0]!)
        .maybeSingle();
      return data?.status ?? null;
    })
    .toBe('absent');

  // An exemption is an entitlement decision and a debarment a disciplinary
  // one; neither is offered, and set_exam_attendance() refuses both anyway.
  await expect(page.getByTestId('mark-status-2').locator('option[value="exempt"]')).toBeDisabled();
  await expect(page.getByTestId('mark-status-2').locator('option[value="debarred"]')).toBeDisabled();
});
