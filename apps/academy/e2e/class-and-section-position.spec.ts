import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-J05: class and section position, through the real UI.
//
//   AC1  section totals of 480, 472, 472 and 465 are positions 1, 2, 2 and 3,
//        and the "out of" is the number of RANKED candidates rather than the
//        section strength.
//   AC2  under 'exclude_absentees' a candidate absent in a paper has no
//        position at all, and the screen prints a dash.
//   AC3  a class of three sections stores both positions for every ranked
//        candidate, and the class denominator is not the section one.
//   AC4  a mark change in section C re-ranks the whole class and marks every
//        report card in it stale until the term results are recomputed.
//
// Plus the properties the acceptance criteria do not state: a class rank is
// refused until every section is signed off and NAMES the one it waits on, and
// the ranking policy is a stored setting rather than an implicit ORDER BY.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * Class 9 in three sections sitting one Physics paper out of 500. One paper is
 * deliberate: the total a candidate is ranked on is then the mark entered, so
 * AC1's four figures can be read straight off the seed.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@position-e2e.test`;
  const controllerEmail = `controller-${runId}@position-e2e.test`;
  const principalEmail = `principal-${runId}@position-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `position-e2e-${runId}`,
    p_legal_name: `Position E2E School ${runId}`,
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

  const makeSection = async (name: string) => {
    const { data, error } = await db
      .from('class_section')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: class9!.id,
        name,
        capacity: 40,
      })
      .select('id')
      .single();
    if (error) throw error;
    return data!.id as string;
  };
  const sectionA = await makeSection('A');
  const sectionB = await makeSection('B');
  const sectionC = await makeSection('C');

  const { data: term, error: termError } = await db
    .from('exam_term')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      code: 'FINAL',
      name: 'Final Term',
      sequence: 1,
      weight_bp: 10000,
      counts_toward_annual: true,
      status: 'active',
    })
    .select('id')
    .single();
  if (termError) throw termError;

  const { data: examSubject, error: esError } = await ownerClient.rpc('upsert_exam_subject', {
    p_exam_term_id: term!.id,
    p_class_subject_id: csPhysics!.id,
    p_components: [{ component: 'theory', max_marks: 500, pass_marks: 0 }],
  });
  if (esError) throw esError;

  let roll = 0;
  const enrol = async (name: string, sectionId: string) => {
    roll += 1;
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: name,
      p_dob: '2011-01-01',
      p_gender: 'female',
      p_father_name_en: 'Muhammad Noor',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    const { error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: sectionId,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    const { data: enrolment } = await db
      .from('enrolment')
      .update({ roll_no: roll })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db
      .from('student')
      .select('gr_number')
      .eq('id', studentId as string)
      .single();
    return { enrolmentId: enrolment!.id as string, grNumber: student!.gr_number as string, name };
  };

  const enterMarks = async (rows: { enrolmentId: string; value: number }[]) => {
    const { error } = await controllerClient.rpc('fn_upsert_marks', {
      p_payload: {
        exam_subject_id: examSubject as string,
        marks: rows.map((r) => ({ enrolment_id: r.enrolmentId, component: 'theory', marks_obtained: r.value })),
      },
    });
    if (error) throw error;
  };
  const markAbsent = async (enrolmentId: string) => {
    const { error } = await controllerClient.rpc('set_exam_attendance', {
      p_exam_subject_id: examSubject as string,
      p_enrolment_id: enrolmentId,
      p_status: 'absent',
      p_reason: 'medical',
    });
    if (error) throw error;
  };
  const approve = async (sectionId: string) => {
    const { error } = await controllerClient.rpc('fn_approve_marks', {
      p_exam_subject_id: examSubject as string,
      p_section_id: sectionId,
    });
    if (error) throw error;
  };

  return {
    db,
    controllerEmail,
    controllerClient,
    principalClient,
    termId: term!.id as string,
    examSubject: examSubject as string,
    sectionA,
    sectionB,
    sectionC,
    enrol,
    enterMarks,
    markAbsent,
    approve,
  };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function openMeritList(page: import('@playwright/test').Page) {
  await page.goto('/exams/results');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('position-class-select').selectOption({ label: 'Class 9' });
  await page.getByTestId('open-positions').click();
  await expect(page.getByTestId('position-sheet')).toBeVisible();
}

test('positions are dense-ranked in the section and in the class, wait for every section, and go stale across the whole class', async ({
  page,
}) => {
  // Three sections, seven candidates and five trips through the merit list —
  // the default 30s covers the assertions but not the seeding as well.
  test.setTimeout(180_000);

  const {
    controllerEmail,
    controllerClient,
    principalClient,
    termId,
    examSubject,
    sectionA,
    sectionB,
    sectionC,
    enrol,
    enterMarks,
    markAbsent,
    approve,
  } = await seed();

  const ayesha = await enrol('Ayesha Noor', sectionA);
  const bilal = await enrol('Bilal Ahmed', sectionA);
  const chandni = await enrol('Chandni Rao', sectionA);
  const danish = await enrol('Danish Ali', sectionA);
  const emaan = await enrol('Emaan Zafar', sectionA);
  const farhan = await enrol('Farhan Iqbal', sectionB);
  const hina = await enrol('Hina Sattar', sectionC);

  await signIn(page, controllerEmail);
  await openMeritList(page);

  // Nothing is marked yet, so nothing is ranked and the screen says what it is
  // waiting for rather than showing an empty table.
  await expect(page.getByTestId('position-none')).toBeVisible();
  await expect(page.getByTestId('position-pending-sections')).toContainText('A, B, C');

  // AC1's four figures, plus an absentee and two other sections.
  await enterMarks([
    { enrolmentId: ayesha.enrolmentId, value: 480 },
    { enrolmentId: bilal.enrolmentId, value: 472 },
    { enrolmentId: chandni.enrolmentId, value: 472 },
    { enrolmentId: danish.enrolmentId, value: 465 },
  ]);
  await markAbsent(emaan.enrolmentId);
  await enterMarks([{ enrolmentId: farhan.enrolmentId, value: 490 }]);
  await enterMarks([{ enrolmentId: hina.enrolmentId, value: 475 }]);

  await approve(sectionA);
  await approve(sectionB);

  // ── Two sections of three ranks nobody, and NAMES the third ────────────
  await openMeritList(page);
  await expect(page.getByTestId('position-none')).toBeVisible();
  await expect(page.getByTestId('position-pending-sections')).toHaveText('C');
  await page.getByTestId('recompute-positions').click();
  await expect(page.getByText('positions wait on section C')).toBeVisible();

  await approve(sectionC);

  // ── AC1 ────────────────────────────────────────────────────────────────
  await openMeritList(page);
  await expect(page.getByTestId(`position-section-${ayesha.grNumber}`)).toHaveText('1 of 4');
  await expect(page.getByTestId(`position-section-${bilal.grNumber}`)).toHaveText('2 of 4');
  await expect(page.getByTestId(`position-section-${chandni.grNumber}`)).toHaveText('2 of 4');
  // 3, not 4: the shared position does not consume the one after it.
  await expect(page.getByTestId(`position-section-${danish.grNumber}`)).toHaveText('3 of 4');
  // "out of 4" while the section holds 5 — the two figures are different on purpose.
  await expect(page.getByTestId('position-ranked-count')).toHaveText('6 of 7 candidates ranked');

  // ── AC2 ────────────────────────────────────────────────────────────────
  await expect(page.getByTestId(`position-section-${emaan.grNumber}`)).toHaveText('—');
  await expect(page.getByTestId(`position-class-${emaan.grNumber}`)).toContainText('—');
  await expect(page.getByTestId(`position-excluded-${emaan.grNumber}`)).toContainText('Absent in a paper');

  // ── AC3: both positions, and two different denominators ────────────────
  await expect(page.getByTestId(`position-class-${farhan.grNumber}`)).toContainText('1 of 6');
  await expect(page.getByTestId(`position-section-${farhan.grNumber}`)).toHaveText('1 of 1');
  await expect(page.getByTestId(`position-class-${ayesha.grNumber}`)).toContainText('2 of 6');
  await expect(page.getByTestId(`position-class-${hina.grNumber}`)).toContainText('3 of 6');
  await expect(page.getByTestId(`position-class-${chandni.grNumber}`)).toContainText('4 of 6');
  await expect(page.getByTestId(`position-class-${danish.grNumber}`)).toContainText('5 of 6');

  // ── AC4: one mark in section C stales section A too ────────────────────
  const { data: requestId, error: requestError } = await controllerClient.rpc('request_mark_unlock', {
    p_exam_subject_id: examSubject,
    p_section_id: sectionC,
    p_reason: 'Q9 total mis-added on Hina’s script',
  });
  if (requestError) throw requestError;
  const { error: grantError } = await principalClient.rpc('fn_break_glass_unlock', {
    p_request_id: requestId as string,
    p_window_minutes: 60,
  });
  if (grantError) throw grantError;
  const { error: fixError } = await controllerClient.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: examSubject,
      // 485 puts her past Ayesha (480) and behind Farhan (490) — a section-C
      // correction that moves section A's topper down a place in the class.
      marks: [{ enrolment_id: hina.enrolmentId, component: 'theory', marks_obtained: 485 }],
    },
  });
  if (fixError) throw fixError;

  await openMeritList(page);
  await expect(page.getByTestId('position-stale-banner')).toContainText('not just the candidate whose marks moved');
  await page.getByTestId('recompute-positions').click();
  await expect(page.getByText('marks are open under a break-glass window on Physics')).toBeVisible();

  const { error: relockError } = await principalClient.rpc('fn_relock_expired_unlocks', {
    p_as_of: new Date(Date.now() + 5 * 3600_000).toISOString(),
  });
  if (relockError) throw relockError;
  const { error: recomputeError } = await controllerClient.rpc('fn_compute_subject_result', {
    p_exam_term_id: termId,
    p_section_id: sectionC,
  });
  if (recomputeError) throw recomputeError;

  await openMeritList(page);
  await expect(page.getByTestId('position-stale-banner')).toHaveCount(0);
  await expect(page.getByTestId(`position-class-${hina.grNumber}`)).toContainText('2 of 6');
  await expect(page.getByTestId(`position-class-${ayesha.grNumber}`)).toContainText('3 of 6');
  // Her SECTION position is untouched — it is a different cohort.
  await expect(page.getByTestId(`position-section-${ayesha.grNumber}`)).toHaveText('1 of 4');

  // ── The policy is a stored setting, and it moves the cohort ────────────
  await page.getByTestId('rank-policy-select').selectOption('include_all');
  await expect(page.getByTestId('position-policy')).toContainText('Include everyone');
  await page.getByTestId('recompute-positions').click();
  await expect(page.getByTestId('position-ranked-count')).toHaveText('7 of 7 candidates ranked');
  await expect(page.getByTestId(`position-section-${emaan.grNumber}`)).toHaveText('4 of 5');
  await expect(page.getByTestId(`position-section-${ayesha.grNumber}`)).toHaveText('1 of 5');
});
