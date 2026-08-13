import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-J03: weighted aggregation across terms, through the real UI.
//
//   AC1  First 25% at 60%, Mid 15% at 70%, Final 60% at 80% -> 73.50%.
//   AC2  a counting term still being marked -> 'provisional', and the screen
//        says report cards cannot be published.
//   AC3  a candidate admitted after the First Term has the missing 25%
//        redistributed pro rata and the row reads "pro-rated, 2 of 3 terms".
//   AC4  a break-glass correction marks the year stale on screen.
//
// Plus FR-I01 AC4 a level up: the weekly-test term is printed on the report
// card and is visibly outside the total.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * One section of Class 9 sitting Physics out of 100 in four terms — three that
 * count (25/15/60) and a weekly-test set that does not. Physics out of 100 is
 * deliberate: a mark and a percentage are then the same number, so the
 * weighted arithmetic can be read straight off the marks entered.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@annual-e2e.test`;
  const controllerEmail = `controller-${runId}@annual-e2e.test`;
  const principalEmail = `principal-${runId}@annual-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `annual-e2e-${runId}`,
    p_legal_name: `Annual E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller' | 'principal', fullName: string) => {
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
  await makeUser(controllerEmail, 'exam_controller', 'Shaista Kamal');
  await makeUser(principalEmail, 'principal', 'Tahira Aziz');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);
  const principalClient = await signedIn(principalEmail);

  const { data: scheme, error: schemeError } = await controllerClient.rpc('save_grading_scheme', {
    p_board: 'FBISE',
    p_name: 'FBISE 2025',
    p_effective_from: '2000-01-01',
    p_bands: [
      { grade_label: 'A1', min_pct: 80, max_pct: 100, gpa_point: 4.0 },
      { grade_label: 'A', min_pct: 70, max_pct: 79.99, gpa_point: 3.7 },
      { grade_label: 'B', min_pct: 60, max_pct: 69.99, gpa_point: 3.3 },
      { grade_label: 'C', min_pct: 50, max_pct: 59.99, gpa_point: 3.0 },
      { grade_label: 'D', min_pct: 40, max_pct: 49.99, gpa_point: 2.5 },
      { grade_label: 'E', min_pct: 33, max_pct: 39.99, gpa_point: 2.0 },
      { grade_label: 'F', min_pct: 0, max_pct: 32.99, gpa_point: 0, is_pass: false },
    ],
  });
  if (schemeError) throw schemeError;
  const { error: activateError } = await controllerClient.rpc('activate_grading_scheme', {
    p_scheme_id: scheme as string,
  });
  if (activateError) throw activateError;

  const { data: class9 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '9').single();

  const { data: physics, error: subjectError } = await db
    .from('subject')
    .insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' })
    .select('id')
    .single();
  if (subjectError) throw subjectError;

  const { data: csPhysics, error: csError } = await db
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
  if (csError) throw csError;

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

  // 2500 + 1500 + 6000 = 10000 basis points across the counting terms. The
  // weekly-test set carries a real 20.00% and is outside that total.
  const makeTerm = async (code: string, name: string, sequence: number, bp: number, counts = true) => {
    const { data, error } = await db
      .from('exam_term')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        code,
        name,
        sequence,
        weight_bp: bp,
        counts_toward_annual: counts,
        status: 'active',
      })
      .select('id')
      .single();
    if (error) throw error;
    return data!.id;
  };
  const termFirst = await makeTerm('T1', 'First Term', 1, 2500);
  const termMid = await makeTerm('T2', 'Mid Term', 2, 1500);
  const termFinal = await makeTerm('T3', 'Final Term', 3, 6000);
  await makeTerm('WK', 'Weekly Tests', 4, 2000, false);

  const examSubject = async (examTermId: string) => {
    const { data, error } = await ownerClient.rpc('upsert_exam_subject', {
      p_exam_term_id: examTermId,
      p_class_subject_id: csPhysics!.id,
      p_components: [{ component: 'theory', max_marks: 100, pass_marks: 0 }],
    });
    if (error) throw error;
    return data as string;
  };
  const esFirst = await examSubject(termFirst);
  const esMid = await examSubject(termMid);
  const esFinal = await examSubject(termFinal);

  const enrol = async (name: string, dob: string, rollNo: number) => {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: name,
      p_dob: dob,
      p_gender: 'female',
      p_father_name_en: 'Muhammad Noor',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    const { error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    const { data: enrolment } = await db
      .from('enrolment')
      .update({ roll_no: rollNo })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db
      .from('student')
      .select('gr_number')
      .eq('id', studentId as string)
      .single();
    return { enrolmentId: enrolment!.id, grNumber: student!.gr_number, name };
  };

  const enterMarks = async (examSubjectId: string, rows: { enrolmentId: string; value: number }[]) => {
    const { error } = await controllerClient.rpc('fn_upsert_marks', {
      p_payload: {
        exam_subject_id: examSubjectId,
        marks: rows.map((r) => ({
          enrolment_id: r.enrolmentId,
          component: 'theory',
          marks_obtained: r.value,
        })),
      },
    });
    if (error) throw error;
  };
  const approve = async (examSubjectId: string) => {
    const { error } = await controllerClient.rpc('fn_approve_marks', {
      p_exam_subject_id: examSubjectId,
      p_section_id: section!.id,
    });
    if (error) throw error;
  };

  const ayesha = await enrol('Ayesha Noor', '2011-01-01', 1);

  return {
    db,
    controllerEmail,
    controllerClient,
    principalClient,
    sectionId: section!.id as string,
    esFirst,
    esMid,
    esFinal,
    ayesha,
    enrol,
    enterMarks,
    approve,
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

async function openAnnual(page: import('@playwright/test').Page) {
  await page.goto('/exams/annual');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('annual-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('open-annual').click();
  await expect(page.getByTestId('annual-sheet')).toBeVisible();
}

test('the year is the weighted sum of its terms, pro-rated for a mid-session admission and provisional until every term is in', async ({
  page,
}) => {
  const {
    controllerEmail,
    controllerClient,
    principalClient,
    sectionId,
    esFirst,
    esMid,
    esFinal,
    ayesha,
    enrol,
    enterMarks,
    approve,
  } = await seed();

  await signIn(page, controllerEmail);
  await openAnnual(page);

  // The weightage is stated before any number is: 25 / 15 / 60, plus the
  // weekly tests that are on the card and outside the total.
  await expect(page.getByTestId('annual-term-T1')).toContainText('First Term — 25.00%');
  await expect(page.getByTestId('annual-term-T3')).toContainText('Final Term — 60.00%');
  await expect(page.getByTestId('annual-non-counting')).toContainText('Weekly Tests (20.00%)');
  await expect(page.getByTestId('annual-none')).toBeVisible();

  // ── First Term. Ayesha is the only candidate; Bilal transfers in later. ──
  await enterMarks(esFirst, [{ enrolmentId: ayesha.enrolmentId, value: 60 }]);
  await approve(esFirst);

  await openAnnual(page);
  // ── AC2 ────────────────────────────────────────────────────────────────
  await expect(page.getByTestId('annual-provisional-banner')).toContainText('cannot be published');
  await expect(page.getByTestId('annual-pending-terms')).toContainText('Mid Term, Final Term');
  await expect(page.getByTestId(`annual-status-${ayesha.grNumber}-Physics`)).toContainText('provisional');

  // ── Bilal's father is posted to another city in January. ───────────────
  const bilal = await enrol('Bilal Ahmed', '2011-02-01', 2);

  await enterMarks(esMid, [
    { enrolmentId: ayesha.enrolmentId, value: 70 },
    { enrolmentId: bilal.enrolmentId, value: 70 },
  ]);
  await approve(esMid);
  await enterMarks(esFinal, [
    { enrolmentId: ayesha.enrolmentId, value: 80 },
    { enrolmentId: bilal.enrolmentId, value: 80 },
  ]);
  await approve(esFinal);

  await openAnnual(page);
  await expect(page.getByTestId('annual-provisional-banner')).toHaveCount(0);

  // ── AC1 ────────────────────────────────────────────────────────────────
  const ayeshaRow = page.getByTestId(`annual-${ayesha.grNumber}-Physics`);
  await expect(ayeshaRow).toContainText('73.50%');
  await expect(ayeshaRow).toContainText('A');
  await expect(ayeshaRow).toContainText('Pass');
  await expect(ayeshaRow).toContainText('3 of 3');
  await expect(page.getByTestId(`annual-status-${ayesha.grNumber}-Physics`)).toHaveCount(0);

  // ── AC3: the missing First Term is redistributed, and printed ──────────
  const bilalRow = page.getByTestId(`annual-${bilal.grNumber}-Physics`);
  // Scoring the missing term zero would give 58.50%; pro rata gives 78.00%.
  await expect(bilalRow).toContainText('78.00%');
  await expect(page.getByTestId(`annual-prorated-${bilal.grNumber}-Physics`)).toContainText(
    'pro-rated, 2 of 3 terms',
  );

  // The stored figures, checked in the database rather than inferred from the
  // screen — this is what FR-J05 and FR-J09 read.
  const { data: rows } = await controllerClient
    .from('annual_result')
    .select('enrolment_id, weighted_pct, status, terms_counted, terms_total, prorated_terms')
    .eq('section_id', sectionId);
  expect(rows!.length).toBe(2);
  expect(rows!.every((r) => r.status === 'final')).toBe(true);
  expect(Number(rows!.find((r) => r.enrolment_id === ayesha.enrolmentId)!.weighted_pct)).toBe(73.5);
  expect(rows!.find((r) => r.enrolment_id === bilal.enrolmentId)!.terms_counted).toBe(2);

  // ── AC4: a break-glass correction marks the year stale ─────────────────
  const { data: requestId, error: requestError } = await controllerClient.rpc('request_mark_unlock', {
    p_exam_subject_id: esFinal,
    p_section_id: sectionId,
    p_reason: 'Q7 total mis-added on Ayesha’s final script',
  });
  if (requestError) throw requestError;
  const { error: grantError } = await principalClient.rpc('fn_break_glass_unlock', {
    p_request_id: requestId as string,
    p_window_minutes: 60,
  });
  if (grantError) throw grantError;
  const { error: fixError } = await controllerClient.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: esFinal,
      marks: [{ enrolment_id: ayesha.enrolmentId, component: 'theory', marks_obtained: 90 }],
    },
  });
  if (fixError) throw fixError;

  await openAnnual(page);
  await expect(page.getByTestId('annual-stale-banner')).toContainText('recomputing the year on its own');
  await expect(page.getByTestId(`annual-stale-${ayesha.grNumber}-Physics`)).toBeVisible();

  // Recomputing inside an open window is refused, for FR-J02's reason.
  await page.getByTestId('recompute-annual').click();
  await expect(page.getByText('marks are open under a break-glass window on Physics')).toBeVisible();

  // Recomputing the TERM is what clears it, and the year follows in the same
  // transaction: 25%*60 + 15%*70 + 60%*90 = 79.50.
  const { error: relockError } = await principalClient.rpc('fn_relock_expired_unlocks', {
    p_as_of: new Date(Date.now() + 5 * 3600_000).toISOString(),
  });
  if (relockError) throw relockError;
  const { error: recomputeError } = await controllerClient.rpc('fn_compute_subject_result', {
    p_exam_term_id: (await controllerClient.from('exam_term').select('id').eq('code', 'T3').single()).data!.id,
    p_section_id: sectionId,
  });
  if (recomputeError) throw recomputeError;

  await openAnnual(page);
  await expect(page.getByTestId('annual-stale-banner')).toHaveCount(0);
  await expect(page.getByTestId(`annual-${ayesha.grNumber}-Physics`)).toContainText('79.50%');
});
