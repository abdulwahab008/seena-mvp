import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-J08: result withheld on fee default, through the real UI.
//
//   AC1  dues of PKR 12,000 against a threshold of PKR 5,000 withhold the
//        candidate, and the parent portal reads "Result withheld — please
//        contact the accounts office" with no marks and no position.
//   AC2  the parent pays and the next sync clears the withhold with no staff
//        action beyond running the job.
//   AC3  the Principal grants a hardship release with a reason: the result
//        becomes available while the dues remain outstanding, and the next
//        sync does not undo it.
//   AC4  a withheld candidate's marks, grades and position stay fully visible
//        on the internal screens.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/** Class 9 section A sitting one Physics paper out of 500. */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@withhold-e2e.test`;
  const controllerEmail = `controller-${runId}@withhold-e2e.test`;
  const principalEmail = `principal-${runId}@withhold-e2e.test`;
  const accountantEmail = `accounts-${runId}@withhold-e2e.test`;
  const parentEmail = `mother-${runId}@withhold-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `withhold-e2e-${runId}`,
    p_legal_name: `Withhold E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (
    email: string,
    role: 'owner' | 'exam_controller' | 'principal' | 'accountant' | 'parent',
    fullName: string,
  ) => {
    const { data: created, error } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (error || !created.user) throw error ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await db
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenant, app_role: role, full_name: fullName });
    if (appUserError) throw appUserError;
    // A parent has no campus scope: their reach is their own children.
    if (role !== 'parent') {
      const { error: campusError } = await db
        .from('user_campus')
        .insert({ user_id: created.user.id, tenant_id: tenant, campus_id: campus!.id });
      if (campusError) throw campusError;
    }
    return created.user.id;
  };
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  await makeUser(controllerEmail, 'exam_controller', 'Shaista Kamal');
  await makeUser(principalEmail, 'principal', 'Tahira Aziz');
  await makeUser(accountantEmail, 'accountant', 'Accounts Clerk');
  const parentUserId = await makeUser(parentEmail, 'parent', 'Ayesha Mother');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);
  const accountantClient = await signedIn(accountantEmail);

  const { error: schemeError, data: scheme } = await controllerClient.rpc('save_grading_scheme', {
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
  const { error: activateError } = await controllerClient.rpc('activate_grading_scheme', { p_scheme_id: scheme as string });
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

  const { data: sectionA, error: sectionError } = await db
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
  if (sectionError) throw sectionError;

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
  const enrol = async (name: string) => {
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
      p_section_id: sectionA!.id,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    const { data: enrolment } = await db
      .from('enrolment')
      .update({ roll_no: roll })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db.from('student').select('gr_number').eq('id', studentId as string).single();
    return { studentId: studentId as string, enrolmentId: enrolment!.id as string, grNumber: student!.gr_number as string, name };
  };

  /** Money is paisa as bigint (FR-K24), so PKR 12,000 is 1,200,000. */
  const charge = async (enrolmentId: string, paisa: number) => {
    const { error } = await accountantClient.rpc('post_ledger_entry', {
      p_enrolment_id: enrolmentId,
      p_entry_type: 'charge',
      p_amount_paisa: paisa,
      p_direction: 'debit',
    });
    if (error) throw error;
  };
  const pay = async (enrolmentId: string, paisa: number) => {
    const { error } = await accountantClient.rpc('post_ledger_entry', {
      p_enrolment_id: enrolmentId,
      p_entry_type: 'payment',
      p_amount_paisa: paisa,
      p_direction: 'credit',
    });
    if (error) throw error;
  };

  const linkParent = async (studentId: string) => {
    const { data: guardianId, error } = await ownerClient.rpc('fn_find_or_create_guardian', {
      p_name_en: 'Ayesha Mother',
      p_phone_e164: `+9230055${String(Math.floor(Math.random() * 90000) + 10000)}`,
    });
    if (error) throw error;
    const { error: linkError } = await ownerClient.rpc('link_guardian', {
      p_student_id: studentId,
      p_guardian_id: guardianId as string,
      p_relationship: 'mother',
      p_is_primary: true,
      p_may_collect_child: true,
      p_receives_academic: true,
      p_receives_billing: true,
    });
    if (linkError) throw linkError;
    const { error: authError } = await db
      .from('guardian')
      .update({ auth_user_id: parentUserId })
      .eq('id', guardianId as string);
    if (authError) throw authError;
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
  const approve = async () => {
    const { error } = await controllerClient.rpc('fn_approve_marks', {
      p_exam_subject_id: examSubject as string,
      p_section_id: sectionA!.id,
    });
    if (error) throw error;
  };

  return {
    db,
    accountantEmail,
    principalEmail,
    parentEmail,
    enrol,
    charge,
    pay,
    linkParent,
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
  // Where sign-in lands depends on the role (staff go to /campuses, a parent
  // to the portal), so the assertion is only that it left the login page —
  // navigating on before it does gets bounced straight back here.
  await page.waitForURL((url) => !url.pathname.startsWith('/login'));
}

async function openWithholds(page: import('@playwright/test').Page) {
  await page.goto('/exams/results');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('withhold-class-select').selectOption({ label: 'Class 9' });
  await page.getByTestId('open-withholds').click();
  await expect(page.getByTestId('withhold-sheet')).toBeVisible();
}

test('a fee defaulter is withheld from the parent and the report card, stays visible internally, and is released by payment or by hardship', async ({
  page,
}) => {
  test.setTimeout(180_000);

  const { accountantEmail, principalEmail, parentEmail, enrol, charge, pay, linkParent, enterMarks, approve } =
    await seed();

  const ayesha = await enrol('Ayesha Noor');
  const bilal = await enrol('Bilal Ahmed');
  const chandni = await enrol('Chandni Rao');
  await linkParent(ayesha.studentId);

  // PKR 12,000 owed by two candidates; Bilal is charged and pays in full.
  await charge(ayesha.enrolmentId, 1_200_000);
  await charge(chandni.enrolmentId, 1_200_000);
  await charge(bilal.enrolmentId, 1_200_000);
  await pay(bilal.enrolmentId, 1_200_000);

  await enterMarks([
    { enrolmentId: ayesha.enrolmentId, value: 480 },
    { enrolmentId: bilal.enrolmentId, value: 472 },
    { enrolmentId: chandni.enrolmentId, value: 465 },
  ]);
  await approve();

  // ── The threshold, and the sync ────────────────────────────────────────
  await signIn(page, accountantEmail);
  await openWithholds(page);

  // Nothing is withheld before a sync: a withhold is a stored decision, not a
  // balance read at print time.
  await expect(page.getByTestId('withhold-count')).toHaveText('0 of 3 candidates withheld');
  await expect(page.getByTestId(`withhold-balance-${ayesha.grNumber}`)).toHaveText('PKR 12,000');

  await page.getByTestId('withhold-threshold-input').fill('5000');
  await page.getByTestId('save-withhold-threshold').click();
  await expect(page.getByTestId('withhold-threshold')).toHaveText('Threshold: PKR 5,000.');

  await page.getByTestId('sync-withholds').click();
  await expect(page.getByTestId('withhold-count')).toHaveText('2 of 3 candidates withheld');

  // ── AC1: the amount, the cut-off and the threshold, on the staff screen ─
  await expect(page.getByTestId(`withhold-state-${ayesha.grNumber}`)).toHaveText('Withheld — Fee default');
  await expect(page.getByTestId(`withhold-reason-${ayesha.grNumber}`)).toContainText(
    'outstanding dues of PKR 12,000',
  );
  await expect(page.getByTestId(`withhold-reason-${ayesha.grNumber}`)).toContainText('exceed the PKR 5,000 threshold');
  await expect(page.getByTestId(`withhold-state-${bilal.grNumber}`)).toHaveText('Released');

  // ── AC4: computation is untouched, and staff still see all of it ────────
  await page.getByTestId('position-class-select').selectOption({ label: 'Class 9' });
  await page.getByTestId('open-positions').click();
  await expect(page.getByTestId('position-sheet')).toBeVisible();
  await expect(page.getByTestId(`position-section-${ayesha.grNumber}`)).toHaveText('1 of 3');
  await expect(page.getByTestId('position-ranked-count')).toHaveText('3 of 3 candidates ranked');

  // ── AC1: the parent's half ─────────────────────────────────────────────
  await page.context().clearCookies();
  await signIn(page, parentEmail);
  await page.goto('/portal/results');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('portal-result-withheld')).toHaveText(
    'Result withheld — please contact the accounts office',
  );
  await expect(page.getByTestId('portal-result-table')).toHaveCount(0);

  // ── AC3: the Principal's hardship release ──────────────────────────────
  await page.context().clearCookies();
  await signIn(page, principalEmail);
  await openWithholds(page);
  await page.getByTestId(`release-withhold-${chandni.grNumber}`).click();
  await page
    .getByTestId('withhold-reason-input')
    .fill('Hardship: father hospitalised, dues rescheduled to September');
  await page.getByTestId('confirm-withhold-reason').click();
  await expect(page.getByTestId(`withhold-hardship-${chandni.grNumber}`)).toContainText(
    'dues still outstanding',
  );
  // The dues really are still outstanding — a release is not a payment.
  await expect(page.getByTestId(`withhold-balance-${chandni.grNumber}`)).toHaveText('PKR 12,000');

  // ── AC2: the money arrives, and the same sync clears it ────────────────
  await pay(ayesha.enrolmentId, 700_000);
  await page.getByTestId('sync-withholds').click();
  await expect(page.getByTestId('withhold-count')).toHaveText('0 of 3 candidates withheld');
  // AC3 survives the tick that would otherwise undo it.
  await expect(page.getByTestId(`withhold-hardship-${chandni.grNumber}`)).toContainText('dues still outstanding');

  await page.context().clearCookies();
  await signIn(page, parentEmail);
  await page.goto('/portal/results');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('portal-result-table')).toBeVisible();
  await expect(page.getByTestId('portal-result-Physics')).toContainText('480');
});
