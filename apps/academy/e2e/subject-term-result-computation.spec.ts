import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-J02: subject term result computation, through the real UI.
//
//   AC1  theory 48 of 65 and practical 16 of 20 -> 64 of 85, 75.29%, grade A,
//        flagged pass.
//   AC2  theory 20 of 65 against a pass mark of 22 with practical 19 of 20 ->
//        45.88% and FAIL, with the failed component named on screen.
//   AC3  an exempt subject contributes 0 obtained and 0 maximum.
//   AC4  an absent one contributes 0 obtained against the full maximum.
//
// Plus what the module rides on: results appear when the LAST paper is signed
// off with nobody asking, a debarred candidate's result is withheld rather
// than failed, and a break-glass correction makes the section visibly stale
// until it is recomputed.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * One section of Class 9 sitting Physics (theory 65 pass 22 + practical 20
 * pass 7) and Islamiat (theory 50 pass 17), with four candidates covering all
 * four acceptance criteria plus a debarment. Two papers because the automatic
 * computation fires on the LAST lock and one paper cannot demonstrate that.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@result-e2e.test`;
  const controllerEmail = `controller-${runId}@result-e2e.test`;
  const principalEmail = `principal-${runId}@result-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `result-e2e-${runId}`,
    p_legal_name: `Result E2E School ${runId}`,
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

  // The published FBISE scale, effective long before this session started.
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
  const islamiat = await insertSubject('ISL', 'Islamiat', 'اسلامیات');

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
  const csIslamiat = await insertClassSubject(islamiat, 3);

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
    { component: 'theory', max_marks: 65, pass_marks: 22 },
    { component: 'practical', max_marks: 20, pass_marks: 7 },
  ]);
  const esIslamiat = await examSubject(csIslamiat, [{ component: 'theory', max_marks: 50, pass_marks: 17 }]);

  const cohort = [
    { name: 'Ayesha Noor', dob: '2011-01-01' },
    { name: 'Bilal Ahmed', dob: '2011-02-01' },
    { name: 'Chandni Rao', dob: '2011-03-01' },
    { name: 'Danish Ali', dob: '2011-04-01' },
    { name: 'Emaan Zafar', dob: '2011-05-01' },
  ];
  const enrolments: { enrolmentId: string; grNumber: string; name: string }[] = [];
  for (const [i, s] of cohort.entries()) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
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
      .update({ roll_no: i + 1 })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db
      .from('student')
      .select('gr_number')
      .eq('id', studentId as string)
      .single();
    enrolments.push({ enrolmentId: enrolment!.id, grNumber: student!.gr_number, name: s.name });
  }
  const [ayesha, bilal, chandni, danish, emaan] = enrolments;

  // Exam statuses first — a candidate who is not present may not carry a mark.
  const setStatus = async (examSubjectId: string, enrolmentId: string, status: string, reason: string) => {
    const { error } = await controllerClient.rpc('set_exam_attendance', {
      p_exam_subject_id: examSubjectId,
      p_enrolment_id: enrolmentId,
      p_status: status,
      p_reason: reason,
    });
    if (error) throw error;
  };
  await setStatus(esIslamiat, chandni!.enrolmentId, 'exempt', 'religious_exemption');
  await setStatus(esPhysics, danish!.enrolmentId, 'absent', 'medical');
  await setStatus(esPhysics, emaan!.enrolmentId, 'debarred', 'fee_default');

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

  await enterMarks(esPhysics, [
    // AC1
    { enrolmentId: ayesha!.enrolmentId, marks: [{ component: 'theory', value: 48 }, { component: 'practical', value: 16 }] },
    // AC2: the aggregate clears, the theory pass mark of 22 does not.
    { enrolmentId: bilal!.enrolmentId, marks: [{ component: 'theory', value: 20 }, { component: 'practical', value: 19 }] },
    { enrolmentId: chandni!.enrolmentId, marks: [{ component: 'theory', value: 50 }, { component: 'practical', value: 18 }] },
  ]);
  await enterMarks(esIslamiat, [
    { enrolmentId: ayesha!.enrolmentId, marks: [{ component: 'theory', value: 40 }] },
    { enrolmentId: bilal!.enrolmentId, marks: [{ component: 'theory', value: 40 }] },
    { enrolmentId: danish!.enrolmentId, marks: [{ component: 'theory', value: 40 }] },
    { enrolmentId: emaan!.enrolmentId, marks: [{ component: 'theory', value: 40 }] },
  ]);

  return {
    db,
    tenant,
    controllerEmail,
    controllerClient,
    principalClient,
    termId: term!.id as string,
    sectionId: section!.id as string,
    esPhysics,
    esIslamiat,
    ayesha: ayesha!,
    bilal: bilal!,
    chandni: chandni!,
    danish: danish!,
    emaan: emaan!,
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

async function openResults(page: import('@playwright/test').Page) {
  await page.goto('/exams/results');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('result-section-select').selectOption({ label: 'Class 9 — A' });
  await page.getByTestId('open-results').click();
  await expect(page.getByTestId('result-sheet')).toBeVisible();
}

test('signing off the last paper computes every candidate, and the four ways a subject result can end up are all distinct', async ({
  page,
}) => {
  const {
    controllerEmail,
    controllerClient,
    principalClient,
    termId,
    sectionId,
    esPhysics,
    esIslamiat,
    ayesha,
    bilal,
    chandni,
    danish,
    emaan,
  } = await seed();

  await signIn(page, controllerEmail);
  await openResults(page);

  // Nothing is computed while a paper is still unsigned.
  await expect(page.getByTestId('result-not-ready')).toContainText('0 of 2 papers signed off');
  await expect(page.getByTestId('result-none')).toBeVisible();

  const approve = async (examSubjectId: string) => {
    const { error } = await controllerClient.rpc('fn_approve_marks', {
      p_exam_subject_id: examSubjectId,
      p_section_id: sectionId,
    });
    if (error) throw error;
  };
  await approve(esPhysics);
  await openResults(page);
  await expect(page.getByTestId('result-none')).toBeVisible();

  // The LAST lock is what computes — nobody presses anything.
  await approve(esIslamiat);
  await openResults(page);
  await expect(page.getByTestId('result-not-ready')).toHaveCount(0);
  await expect(page.getByTestId('result-scale')).toContainText('FBISE 2025 (v1)');

  // ── AC1 ────────────────────────────────────────────────────────────────
  const ayeshaPhysics = page.getByTestId(`result-${ayesha.grNumber}-Physics`);
  await expect(ayeshaPhysics).toContainText('64.00');
  await expect(ayeshaPhysics).toContainText('85');
  await expect(ayeshaPhysics).toContainText('75.29%');
  await expect(ayeshaPhysics).toContainText('A');
  await expect(ayeshaPhysics).toContainText('Pass');

  // ── AC2: the aggregate clears and the subject still fails ──────────────
  const bilalPhysics = page.getByTestId(`result-${bilal.grNumber}-Physics`);
  await expect(bilalPhysics).toContainText('45.88%');
  await expect(bilalPhysics).toContainText('Fail');
  await expect(page.getByTestId(`result-failed-${bilal.grNumber}-Physics`)).toContainText(
    'theory 20 of a pass mark of 22',
  );

  // ── AC3: exempt leaves the denominator ─────────────────────────────────
  const chandniIslamiat = page.getByTestId(`result-${chandni.grNumber}-Islamiat`);
  await expect(chandniIslamiat).toContainText('EX');
  await expect(chandniIslamiat).toContainText('Exempt — out of the denominator');

  // ── AC4: absent scores 0 against the full maximum ──────────────────────
  const danishPhysics = page.getByTestId(`result-${danish.grNumber}-Physics`);
  await expect(danishPhysics).toContainText('0.00');
  await expect(danishPhysics).toContainText('85');
  await expect(danishPhysics).toContainText('0.00%');
  await expect(danishPhysics).toContainText('F');
  await expect(danishPhysics).toContainText('Fail');

  // A debarment withholds the whole term rather than failing it.
  await expect(page.getByTestId(`result-withheld-${emaan.grNumber}`)).toContainText('Result withheld');
  await expect(page.getByTestId(`result-${emaan.grNumber}-Islamiat`)).toContainText('WITHHELD');

  // The stored numbers, checked in the database rather than inferred from the
  // screen — this is what FR-J03 and FR-J09 will read.
  const { data: rows } = await controllerClient
    .from('subject_result')
    .select('enrolment_id, obtained, max_marks, pct, grade_label, is_pass, is_blocked, report_symbol')
    .eq('exam_term_id', termId);
  expect(rows!.length).toBe(10);
  const chandniTotal = rows!
    .filter((r) => r.enrolment_id === chandni.enrolmentId)
    .reduce((sum, r) => sum + r.max_marks, 0);
  const ayeshaTotal = rows!
    .filter((r) => r.enrolment_id === ayesha.enrolmentId)
    .reduce((sum, r) => sum + r.max_marks, 0);
  // AC3, as an actual denominator: Islamiat's 50 marks left Chandni's total.
  expect(ayeshaTotal).toBe(135);
  expect(chandniTotal).toBe(85);

  // ── FR-I17: a break-glass correction makes the result stale ────────────
  const { data: requestId, error: requestError } = await controllerClient.rpc('request_mark_unlock', {
    p_exam_subject_id: esPhysics,
    p_section_id: sectionId,
    p_reason: 'Q5 total mis-added on Ayesha’s script',
  });
  if (requestError) throw requestError;
  const { error: grantError } = await principalClient.rpc('fn_break_glass_unlock', {
    p_request_id: requestId as string,
    p_window_minutes: 60,
  });
  if (grantError) throw grantError;
  const { error: fixError } = await controllerClient.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: esPhysics,
      marks: [{ enrolment_id: ayesha.enrolmentId, component: 'theory', marks_obtained: 50 }],
    },
  });
  if (fixError) throw fixError;

  await openResults(page);
  await expect(page.getByTestId('result-stale-banner')).toContainText('out of date');
  await expect(page.getByTestId(`result-stale-${ayesha.grNumber}-Physics`)).toBeVisible();
  // Only the paper that was reopened.
  await expect(page.getByTestId(`result-stale-${ayesha.grNumber}-Islamiat`)).toHaveCount(0);

  // Recomputing inside an open window is refused — staleness is stamped once
  // per window, so clearing it early would lose a later edit's signal.
  await page.getByTestId('recompute-results').click();
  await expect(page.getByText('marks are open under a break-glass window on Physics')).toBeVisible();

  // The clock closes it, and only then does the recompute land.
  const { error: relockError } = await principalClient.rpc('fn_relock_expired_unlocks', {
    p_as_of: new Date(Date.now() + 5 * 3600_000).toISOString(),
  });
  if (relockError) throw relockError;

  await openResults(page);
  await page.getByTestId('recompute-results').click();
  await expect(page.getByTestId('result-stale-banner')).toHaveCount(0);
  await expect(page.getByTestId(`result-${ayesha.grNumber}-Physics`)).toContainText('66.00');
  await expect(page.getByTestId(`result-${ayesha.grNumber}-Physics`)).toContainText('77.65%');
});
