import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I16: mark approval and locking, through the real UI.
//
//   AC1  a candidate with neither a mark nor an exam status blocks approval,
//        and their GR number is on the controller's screen before the click.
//   AC2  a complete set approves: marks go to 'locked', the lock row records
//        approver and timestamp, and the teacher's grid comes back read-only.
//   AC3  a service-role write to a locked set is refused with 'marks_locked'.
//   AC4  every subject in the term locked for the class makes term result
//        computation available for that class.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * One section of Class 9 sitting two papers — Physics (theory 65 + practical
 * 20) and Urdu (theory 100) — with three candidates. Two papers because AC4 is
 * about the LAST subject in a term locking, and one paper cannot demonstrate
 * that.
 *
 * Curriculum, allocation and exam setup go in without driving their own
 * screens (they have their own e2e coverage); students and enrolments go
 * through a SIGNED-IN owner, because those RPCs read JWT claims a service-role
 * call never carries — the same reason teacher-mark-entry.spec.ts gives.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@mark-approval-e2e.test`;
  const controllerEmail = `controller-${runId}@mark-approval-e2e.test`;
  const teacherEmail = `phy-${runId}@mark-approval-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `mark-approval-e2e-${runId}`,
    p_legal_name: `Mark Approval E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller' | 'subject_teacher', fullName: string) => {
    const { data: created, error } = await db.auth.admin.createUser({
      email,
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
  await makeUser(controllerEmail, 'exam_controller', 'Rukhsana Bano');
  const teacherId = await makeUser(teacherEmail, 'subject_teacher', 'E2E Physics Teacher');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);

  const { data: class9 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '9').single();

  const insertSubject = async (code: string, nameEn: string, nameUr: string) => {
    const { data, error } = await db
      .from('subject')
      .insert({ tenant_id: tenant, code, name_en: nameEn, name_ur: nameUr })
      .select('id')
      .single();
    if (error) throw error;
    return data!.id;
  };
  const physics = await insertSubject('PHY', 'Physics', 'طبیعیات');
  const urdu = await insertSubject('URD', 'Urdu', 'اردو');

  const insertClassSubject = async (subjectId: string, periods: number) => {
    const { data, error } = await db
      .from('class_subject')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: class9!.id,
        subject_id: subjectId,
        weekly_periods: periods,
      })
      .select('id')
      .single();
    if (error) throw error;
    return data!.id;
  };
  const csPhysics = await insertClassSubject(physics, 5);
  const csUrdu = await insertClassSubject(urdu, 4);

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

  await db.from('section_subject_teacher').insert({
    tenant_id: tenant,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    subject_id: physics,
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

  const examSubject = async (classSubjectId: string, components: unknown[]) => {
    const { data, error } = await ownerClient.rpc('upsert_exam_subject', {
      p_exam_term_id: term!.id,
      p_class_subject_id: classSubjectId,
      p_components: components,
    });
    if (error) throw error;
    return data as string;
  };
  const esPhysics = await examSubject(csPhysics, [
    { component: 'theory', max_marks: 65, pass_marks: 23 },
    { component: 'practical', max_marks: 20, pass_marks: 7 },
  ]);
  const esUrdu = await examSubject(csUrdu, [{ component: 'theory', max_marks: 100, pass_marks: 33 }]);

  const enrolments: { enrolmentId: string; grNumber: string }[] = [];
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
    const { data: enrolment } = await db
      .from('enrolment')
      .update({ roll_no: i + 1 })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db
      .from('student')
      .select('gr_number')
      .eq('id', studentId as string)
      .single();
    enrolments.push({ enrolmentId: enrolment!.id, grNumber: student!.gr_number });
  }

  /** Enters a full paper for the given enrolments as the Exam Controller. */
  const enterMarks = async (
    examSubjectId: string,
    rows: { enrolmentId: string; marks: { component: string; value: number }[] }[],
  ) => {
    const { error } = await controllerClient.rpc('fn_upsert_marks', {
      p_payload: {
        exam_subject_id: examSubjectId,
        marks: rows.flatMap((r) =>
          r.marks.map((m) => ({
            enrolment_id: r.enrolmentId,
            component: m.component,
            marks_obtained: m.value,
          })),
        ),
      },
    });
    if (error) throw error;
  };

  return {
    ownerEmail,
    controllerEmail,
    teacherEmail,
    esPhysics,
    esUrdu,
    enrolments,
    enterMarks,
  };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
}

async function openQueue(page: import('@playwright/test').Page) {
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-queue')).toBeVisible();
}

test('an incomplete paper cannot be approved, a complete one locks against everyone, and the last lock opens result computation', async ({
  page,
}) => {
  const { controllerEmail, teacherEmail, esPhysics, esUrdu, enrolments, enterMarks } = await seed();
  const db = admin();

  const full = (component: string, value: number) => ({ component, value });
  // Two of three candidates fully marked in both papers; the third has nothing
  // at all and no exam status either — AC1's case.
  await enterMarks(
    esPhysics,
    enrolments.slice(0, 2).map((e) => ({
      enrolmentId: e.enrolmentId,
      marks: [full('theory', 55), full('practical', 15)],
    })),
  );
  await enterMarks(
    esUrdu,
    enrolments.slice(0, 2).map((e) => ({ enrolmentId: e.enrolmentId, marks: [full('theory', 70)] })),
  );

  await signIn(page, controllerEmail);
  await openQueue(page);

  // ── AC1: the blocking candidate is named before anything is attempted ──
  await expect(page.getByTestId('approval-not-started-Physics')).toContainText(
    `1 candidate has neither a mark nor an exam status: ${enrolments[2]!.grNumber}`,
  );
  await expect(page.getByTestId('approve-Physics')).toBeDisabled();

  // ── AC4, before: result computation is not available ───────────────────
  await expect(page.getByTestId('approval-result-ready')).toContainText('0 of 2 papers locked');
  await expect(page.getByTestId('approval-pending-subjects')).toContainText('Physics');
  await expect(page.getByTestId('approval-pending-subjects')).toContainText('Urdu');

  // ── AC2: complete the set, then approve ────────────────────────────────
  await enterMarks(esPhysics, [
    { enrolmentId: enrolments[2]!.enrolmentId, marks: [full('theory', 48), full('practical', 12)] },
  ]);
  await openQueue(page);
  await expect(page.getByTestId('approval-not-started-Physics')).toHaveCount(0);
  await expect(page.getByTestId('approve-Physics')).toBeEnabled();
  await page.getByTestId('approve-Physics').click();
  await expect(page.getByTestId('approval-locked-Physics')).toContainText('Locked by Rukhsana Bano');

  // The lock row and the status transition, checked in the database rather
  // than inferred from the screen.
  const { data: locks } = await db
    .from('mark_lock')
    .select('locked_by, locked_at, candidate_count, mark_count, unlock_state')
    .eq('exam_subject_id', esPhysics);
  expect(locks!.length).toBe(1);
  expect(locks![0]!.locked_at).toBeTruthy();
  expect(locks![0]!.candidate_count).toBe(3);
  expect(locks![0]!.mark_count).toBe(6);
  expect(locks![0]!.unlock_state).toBe('locked');

  const { data: physicsMarks } = await db.from('mark_entry').select('status').eq('exam_subject_id', esPhysics);
  expect(physicsMarks!.length).toBe(6);
  expect(physicsMarks!.every((m) => m.status === 'locked')).toBe(true);

  // ── AC3: a service-role job is refused by the trigger ──────────────────
  const { error: serviceUpdate } = await db
    .from('mark_entry')
    .update({ marks_obtained: 1 })
    .eq('exam_subject_id', esPhysics);
  expect(serviceUpdate?.message).toContain('marks_locked');

  const { error: serviceDelete } = await db.from('mark_entry').delete().eq('exam_subject_id', esPhysics);
  expect(serviceDelete?.message).toContain('marks_locked');

  const { data: unchanged } = await db
    .from('mark_entry')
    .select('marks_obtained')
    .eq('exam_subject_id', esPhysics)
    .eq('enrolment_id', enrolments[2]!.enrolmentId)
    .eq('component_code', 'theory')
    .single();
  expect(Number(unchanged!.marks_obtained)).toBe(48);

  // ── AC4: the last paper in the term ────────────────────────────────────
  await expect(page.getByTestId('approval-result-ready')).toContainText('1 of 2 papers locked');
  await expect(page.getByTestId('approval-pending-subjects')).toHaveText('Urdu');
  await enterMarks(esUrdu, [{ enrolmentId: enrolments[2]!.enrolmentId, marks: [full('theory', 61)] }]);
  await openQueue(page);
  await page.getByTestId('approve-Urdu').click();
  await expect(page.getByTestId('approval-result-ready')).toContainText('term result computation is available');

  // Every (paper, section) pair in the term is locked, so FR-I01's
  // lock_exam_term() has been called — the seam it was built for.
  const { data: examSubjectRow } = await db
    .from('exam_subject')
    .select('exam_term_id')
    .eq('id', esPhysics)
    .single();
  const { data: termRow } = await db
    .from('exam_term')
    .select('status, locked_at')
    .eq('id', examSubjectRow!.exam_term_id)
    .single();
  expect(termRow!.status).toBe('locked');
  expect(termRow!.locked_at).toBeTruthy();

  // ── AC2: "the teacher's grid renders read-only on the next load" ───────
  await page.context().clearCookies();
  await signIn(page, teacherEmail);
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Physics' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
  await expect(page.getByTestId('mark-entry-locked')).toContainText('Approved and locked by Rukhsana Bano');
  await expect(page.getByTestId('mark-cell-1-theory')).toBeDisabled();
});

test('a subject teacher cannot open the approval board', async ({ page }) => {
  const { teacherEmail } = await seed();

  await signIn(page, teacherEmail);
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('mark-approvals-forbidden')).toBeVisible();
});
