import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I14: mandatory teacher override of OCR marks, through the real UI.
//
//   AC1  scripts with OCR suggestions and no review actions: Submit marks is
//        refused with "0 of 12 scripts reviewed", and the exam office cannot
//        sign the set off either.
//   AC2  the teacher accepts the rest unchanged and amends one script from 52
//        to 55: mark_entry holds one row per script, 'ocr_confirmed' for the
//        accepted ones and 'ocr_overridden' for the amended one, with the
//        original OCR value preserved.
//   AC3  a bulk accept of a page of 10 writes TEN review rows with actor and
//        timestamp, not one row for the page.
//   AC4  the OCR value, the final value, the acting user and the timestamp are
//        all retrievable for that question afterwards.
//
// The batch is created through fn_open_ocr_job() with a SERVICE ROLE key,
// because that is exactly how FR-I13's pipeline will call it — and the point of
// this FR is that even that key cannot turn a machine's reading into a mark.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';
const SCRIPT_COUNT = 12;

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/** Class 9-B sitting one Maths paper, with nothing marked yet. */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@ocr-e2e.test`;
  const controllerEmail = `controller-${runId}@ocr-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `ocr-e2e-${runId}`,
    p_legal_name: `OCR E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller', fullName: string) => {
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
  const controllerId = await makeUser(controllerEmail, 'exam_controller', 'Rukhsana Bano');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);

  const { data: class9 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '9').single();
  const { data: maths } = await db
    .from('subject')
    .insert({ tenant_id: tenant, code: 'MTH', name_en: 'Maths', name_ur: 'ریاضی' })
    .select('id')
    .single();
  const { data: classSubject } = await db
    .from('class_subject')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      subject_id: maths!.id,
      weekly_periods: 6,
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
      name: 'B',
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
    p_components: [{ component: 'theory', max_marks: 100, pass_marks: 33 }],
  });
  if (e4) throw e4;
  const examSubject = examSubjectId as string;

  // Through create_student/enrol_student rather than by INSERT: enrolment is
  // gated (FR-K's admission-fee trigger) and a direct insert silently qualifies
  // no rows.
  const byRoll = new Map<number, string>();
  for (let i = 0; i < SCRIPT_COUNT; i += 1) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: `Candidate ${String(i + 1).padStart(2, '0')}`,
      p_dob: '2011-03-04',
      p_gender: 'male',
      p_father_name_en: 'Muhammad Raza',
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
    if (rollError || !enrolment) throw rollError ?? new Error('enrolment not found');
    byRoll.set(i + 1, enrolment.id);
  }

  return {
    db,
    ownerEmail,
    controllerEmail,
    controllerId,
    examSubject,
    sectionId: section!.id,
    termId: term!.id,
    byRoll,
  };
}

/**
 * FR-I13's seam, called the way FR-I13 will call it: a service_role key hands
 * the machine's reading over and gets a batch of SUGGESTIONS back. The last
 * script is the one the machine read as 52 — AC2's.
 */
async function openBatch(
  db: ReturnType<typeof admin>,
  examSubject: string,
  sectionId: string,
  byRoll: Map<number, string>,
) {
  const { data, error } = await db.rpc('fn_open_ocr_job', {
    p_exam_subject_id: examSubject,
    p_section_id: sectionId,
    p_component: 'theory',
    p_suggestions: [...byRoll.entries()].map(([roll, enrolmentId]) => ({
      enrolment_id: enrolmentId,
      question_no: 1,
      ocr_value: roll === SCRIPT_COUNT ? 52 : 40 + roll,
      confidence: roll === 1 ? 0.999 : 0.812,
    })),
    p_engine: 'seena-ocr-v1',
  });
  if (error) throw error;
  return (data as { job_id: string }).job_id;
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(email);
    await page.getByLabel('Password').fill(PASSWORD);
    await page.getByRole('button', { name: 'Sign in' }).click();
    try {
      await expect(page).toHaveURL(/\/dashboard$/, { timeout: 10_000 });
      return;
    } catch {
      if (attempt === 1) throw new Error(`sign-in failed twice for ${email}`);
    }
  }
}

async function openGrid(page: import('@playwright/test').Page) {
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Maths' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
}

test('a machine cannot mark a script: every suggestion needs a named teacher before it becomes a mark', async ({
  page,
}) => {
  const { db, controllerEmail, controllerId, examSubject, sectionId, byRoll } = await seed();
  const jobId = await openBatch(db, examSubject, sectionId, byRoll);

  // ── AC1: suggestions, and not one mark ─────────────────────────────────
  const { count: marksBefore } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('exam_subject_id', examSubject);
  expect(marksBefore ?? 0).toBe(0);

  await signIn(page, controllerEmail);
  await openGrid(page);

  await expect(page.getByTestId('ocr-review-panel')).toBeVisible();
  await expect(page.getByTestId('ocr-review-progress')).toHaveText(`0 of ${SCRIPT_COUNT} scripts reviewed`);
  await expect(page.getByTestId('ocr-promote')).toBeDisabled();
  await expect(page.getByTestId('ocr-promote-blocked')).toHaveText(`0 of ${SCRIPT_COUNT} scripts reviewed`);

  // The machine was as certain as it gets about roll 1, and it bought nothing.
  await expect(page.getByTestId('ocr-suggested-1-1')).toHaveText('41');
  await expect(page.getByTestId('ocr-reviewed-1-1')).toHaveText('not confirmed');

  // AC1: "the guard must live in the database function that promotes marks,
  // never only in the UI" — so the exam office is refused too.
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-queue')).toBeVisible();
  await expect(page.getByTestId('approval-ocr-unreviewed-Maths')).toContainText(
    `${SCRIPT_COUNT} candidates have an OCR mark no teacher has confirmed`,
  );
  await expect(page.getByTestId('approve-Maths')).toBeDisabled();
  await expect(page.getByTestId('approval-locked-Maths')).toHaveCount(0);

  // The disabled button is decoration; the refusal is the database's. Asked
  // straight through the RPC, with a signed-in Exam Controller's own key.
  const controllerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await controllerClient.auth.signInWithPassword({ email: controllerEmail, password: PASSWORD });
  const { error: refused } = await controllerClient.rpc('fn_approve_marks', {
    p_exam_subject_id: examSubject,
    p_section_id: sectionId,
  });
  expect(refused?.message).toContain(`${SCRIPT_COUNT} candidates have an OCR mark no teacher has confirmed`);

  // ── AC3: a bulk accept of a page of ten ────────────────────────────────
  await openGrid(page);
  await expect(page.getByTestId('ocr-page-label')).toHaveText('Page 1 of 2');
  await page.getByTestId('ocr-accept-page').click();
  await expect(page.getByTestId('ocr-review-progress')).toHaveText(`10 of ${SCRIPT_COUNT} scripts reviewed`);

  const { data: bulkRows } = await db
    .from('ocr_review_action')
    .select('id, enrolment_id, question_no, ocr_value, final_value, actor_id, acted_at')
    .eq('job_id', jobId);
  // Ten rows, not one row for the page — that is the whole of AC3.
  expect(bulkRows!.length).toBe(10);
  expect(new Set(bulkRows!.map((r) => r.enrolment_id)).size).toBe(10);
  expect(bulkRows!.every((r) => r.actor_id === controllerId)).toBe(true);
  expect(bulkRows!.every((r) => r.acted_at !== null)).toBe(true);
  expect(bulkRows!.every((r) => Number(r.final_value) === Number(r.ocr_value))).toBe(true);

  // Ten of twelve is still not twelve.
  await expect(page.getByTestId('ocr-promote')).toBeDisabled();
  const { count: marksMidway } = await db
    .from('mark_entry')
    .select('id', { count: 'exact', head: true })
    .eq('exam_subject_id', examSubject);
  expect(marksMidway ?? 0).toBe(0);

  // ── AC2: the last two, one of them amended from 52 to 55 ───────────────
  await page.getByTestId('ocr-page-next').click();
  await expect(page.getByTestId('ocr-page-label')).toHaveText('Page 2 of 2');
  await expect(page.getByTestId(`ocr-suggested-${SCRIPT_COUNT}-1`)).toHaveText('52');

  await page.getByTestId(`ocr-award-${SCRIPT_COUNT}-1`).fill('55');
  await page.getByTestId(`ocr-confirm-${SCRIPT_COUNT}`).click();
  await expect(page.getByTestId('ocr-review-progress')).toHaveText(`11 of ${SCRIPT_COUNT} scripts reviewed`);

  await page.getByTestId(`ocr-confirm-${SCRIPT_COUNT - 1}`).click();
  await expect(page.getByTestId('ocr-review-progress')).toHaveText(
    `${SCRIPT_COUNT} of ${SCRIPT_COUNT} scripts reviewed`,
  );
  await expect(page.getByTestId('ocr-promote')).toBeEnabled();

  await page.getByTestId('ocr-promote').click();
  await expect(page.getByTestId('ocr-review-panel')).toHaveCount(0);

  const { data: promoted } = await db
    .from('mark_entry')
    .select('enrolment_id, marks_obtained, source, ocr_job_id')
    .eq('exam_subject_id', examSubject);
  expect(promoted!.length).toBe(SCRIPT_COUNT);
  expect(promoted!.filter((m) => m.source === 'ocr_confirmed').length).toBe(SCRIPT_COUNT - 1);
  expect(promoted!.filter((m) => m.source === 'ocr_overridden').length).toBe(1);
  expect(promoted!.every((m) => m.ocr_job_id === jobId)).toBe(true);

  const amendedEnrolment = byRoll.get(SCRIPT_COUNT)!;
  const amended = promoted!.find((m) => m.enrolment_id === amendedEnrolment)!;
  expect(Number(amended.marks_obtained)).toBe(55);
  expect(amended.source).toBe('ocr_overridden');

  // "and the original OCR value is preserved"
  const { data: suggestion } = await db
    .from('ocr_mark_suggestion')
    .select('ocr_value')
    .eq('job_id', jobId)
    .eq('enrolment_id', amendedEnrolment)
    .single();
  expect(Number(suggestion!.ocr_value)).toBe(52);

  // The grid now says which numbers a machine produced, in the cell.
  await expect(page.getByTestId(`mark-cell-${SCRIPT_COUNT}-theory`)).toHaveValue('55');
  await expect(page.getByTestId(`mark-source-badge-${SCRIPT_COUNT}-theory`)).toHaveText('OCR amended');
  await expect(page.getByTestId('mark-source-badge-1-theory')).toHaveText('OCR confirmed');

  // ── AC4: the dispute, six months later ─────────────────────────────────
  const { data: audit } = await db
    .from('v_ocr_mark_audit')
    .select('gr_number, question_no, ocr_value, final_value, actor_name, acted_at, was_overridden')
    .eq('job_id', jobId)
    .eq('enrolment_id', amendedEnrolment)
    .single();
  expect(Number(audit!.ocr_value)).toBe(52);
  expect(Number(audit!.final_value)).toBe(55);
  expect(audit!.actor_name).toBe('Rukhsana Bano');
  expect(audit!.acted_at).not.toBeNull();
  expect(audit!.was_overridden).toBe(true);

  // And with a named human on every script, the set signs off.
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-ocr-unreviewed-Maths')).toHaveCount(0);
  await page.getByTestId('approve-Maths').click();
  await expect(page.getByTestId('approval-locked-Maths')).toBeVisible();
});

test('a scan that came back unusable is abandoned on the record rather than making the section unapprovable', async ({
  page,
}) => {
  const { db, controllerEmail, examSubject, sectionId, byRoll } = await seed();

  // Every mark keyed by hand — and then a batch of the same scripts turns up.
  // not_started and partial are both empty, so this is the set that would be
  // signed off with a machine's unexamined opinion still on file.
  const controllerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await controllerClient.auth.signInWithPassword({ email: controllerEmail, password: PASSWORD });
  const { error: markError } = await controllerClient.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: examSubject,
      marks: [...byRoll.values()].map((id) => ({ enrolment_id: id, component: 'theory', marks_obtained: 60 })),
    },
  });
  if (markError) throw markError;

  const jobId = await openBatch(db, examSubject, sectionId, byRoll);

  await signIn(page, controllerEmail);
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-not-started-Maths')).toHaveCount(0);
  await expect(page.getByTestId('approval-ocr-unreviewed-Maths')).toContainText(
    `${SCRIPT_COUNT} candidates have an OCR mark no teacher has confirmed`,
  );

  await openGrid(page);
  await expect(page.getByTestId('ocr-cancel')).toBeDisabled();
  await page.getByTestId('ocr-cancel-reason').fill('Scanner fed two scripts together — pages unusable');
  await page.getByTestId('ocr-cancel').click();
  await expect(page.getByTestId('ocr-review-panel')).toHaveCount(0);

  const { data: job } = await db
    .from('ocr_mark_job')
    .select('status, cancelled_reason, cancelled_at')
    .eq('id', jobId)
    .single();
  expect(job!.status).toBe('cancelled');
  expect(job!.cancelled_reason).toBe('Scanner fed two scripts together — pages unusable');
  expect(job!.cancelled_at).not.toBeNull();

  // The hand-keyed marks were never machine marks and say so.
  const { data: marks } = await db
    .from('mark_entry')
    .select('source, ocr_job_id')
    .eq('exam_subject_id', examSubject);
  expect(marks!.length).toBe(SCRIPT_COUNT);
  expect(marks!.every((m) => m.source === 'manual' && m.ocr_job_id === null)).toBe(true);

  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-ocr-unreviewed-Maths')).toHaveCount(0);
  await page.getByTestId('approve-Maths').click();
  await expect(page.getByTestId('approval-locked-Maths')).toBeVisible();
});
