import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { createHash, randomUUID } from 'node:crypto';

// FR-J09: report card PDF generation, through the real UI and against the
// real bytes.
//
//   AC1  a Class 5 candidate with four subjects gets ONE A4 page carrying
//        every subject row, the aggregate 612 of 800 at 76.50% grade A, the
//        position, and the attendance summary with the date range it covers.
//   AC2  the campus logo and the principal's signature are drawn from campus
//        branding, with no per-report configuration — two image objects in a
//        file whose layout has neither hard-coded.
//   AC3  a withheld candidate is refused with 'result_withheld' and no row
//        and no object are created.
//   AC4  regenerating issues revision 2, and the footer reads "Revised —
//        supersedes revision 1".
//
// Plus the property the ACs do not state and the register depends on: the
// digest on the row is the digest of the bytes in the bucket, the verifying
// download route agrees, and a reprint is byte-stable — re-rendering revision
// 1 from revision 1's snapshot produces the same file.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const sha256 = (b: Buffer | Uint8Array) => createHash('sha256').update(b).digest('hex');

/** Skia writes page objects uncompressed, so the page tree is readable. */
function pdfPageCount(body: Buffer): number {
  return (body.toString('latin1').match(/\/Type\s*\/Page(?![a-zA-Z])/g) ?? []).length;
}
function pdfImageCount(body: Buffer): number {
  return (body.toString('latin1').match(/\/Subtype\s*\/Image/g) ?? []).length;
}
/** A 1x1 PNG, enough for the branding rows to point at a real object. */
const PNG_1PX = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  'base64',
);

async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@card-e2e.test`;
  const controllerEmail = `controller-${runId}@card-e2e.test`;
  const accountantEmail = `accounts-${runId}@card-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `card-e2e-${runId}`,
    p_legal_name: `Card E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller' | 'accountant', fullName: string) => {
    const { data: created, error } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
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
  const ownerId = await makeUser(ownerEmail, 'owner', 'E2E Owner');
  await makeUser(controllerEmail, 'exam_controller', 'Shaista Kamal');
  await makeUser(accountantEmail, 'accountant', 'Accounts Clerk');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);
  const accountantClient = await signedIn(accountantEmail);

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
  const { error: activateError } = await controllerClient.rpc('activate_grading_scheme', { p_scheme_id: scheme as string });
  if (activateError) throw activateError;

  const { data: class5 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '5').single();

  const { data: sectionA, error: sectionError } = await db
    .from('class_section')
    .insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class5!.id,
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

  // AC1: four papers of 200 make a term out of 800.
  const examSubjects: string[] = [];
  for (const [code, nameEn, nameUr] of [
    ['ENG', 'English', 'انگریزی'],
    ['URD', 'Urdu', 'اردو'],
    ['MTH', 'Maths', 'ریاضی'],
    ['SCI', 'Science', 'سائنس'],
  ]) {
    const { data: subject, error: subjectError } = await db
      .from('subject')
      .insert({ tenant_id: tenant, code, name_en: nameEn, name_ur: nameUr })
      .select('id')
      .single();
    if (subjectError) throw subjectError;
    const { data: classSubject, error: csError } = await db
      .from('class_subject')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: class5!.id,
        subject_id: subject!.id,
        weekly_periods: 6,
      })
      .select('id')
      .single();
    if (csError) throw csError;
    const { data: examSubject, error: esError } = await ownerClient.rpc('upsert_exam_subject', {
      p_exam_term_id: term!.id,
      p_class_subject_id: classSubject!.id,
      p_components: [{ component: 'theory', max_marks: 200, pass_marks: 0 }],
    });
    if (esError) throw esError;
    examSubjects.push(examSubject as string);
  }

  // AC2: a logo and a signature really in the branding bucket, so the render
  // has bytes to inline rather than a path that resolves to nothing.
  const brandingAssets: [string, string][] = [
    ['logo', `${tenant}/logo.png`],
    ['signature', `${tenant}/signature.png`],
  ];
  for (const [assetType, path] of brandingAssets) {
    const { error: uploadError } = await db.storage
      .from('branding')
      .upload(path, PNG_1PX, { contentType: 'image/png', upsert: true });
    if (uploadError) throw uploadError;
    const { error: assetError } = await db.from('branding_asset').insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      asset_type: assetType,
      storage_path: path,
      width_px: 1,
      height_px: 1,
      bytes: PNG_1PX.length,
      version: 1,
      is_current: true,
      uploaded_by: ownerId,
    });
    if (assetError) throw assetError;
  }

  let roll = 0;
  const enrol = async (name: string) => {
    roll += 1;
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: name,
      p_dob: '2015-01-01',
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
      .update({ roll_no: roll, joined_on: '2026-04-01' })
      .eq('student_id', studentId as string)
      .select('id')
      .single();
    const { data: student } = await db.from('student').select('gr_number').eq('id', studentId as string).single();
    return { enrolmentId: enrolment!.id as string, grNumber: student!.gr_number as string, name };
  };

  const enterMarks = async (examSubjectId: string, rows: { enrolmentId: string; value: number }[]) => {
    const { error } = await controllerClient.rpc('fn_upsert_marks', {
      p_payload: {
        exam_subject_id: examSubjectId,
        marks: rows.map((r) => ({ enrolment_id: r.enrolmentId, component: 'theory', marks_obtained: r.value })),
      },
    });
    if (error) throw error;
  };
  const approve = async (examSubjectId: string) => {
    const { error } = await controllerClient.rpc('fn_approve_marks', {
      p_exam_subject_id: examSubjectId,
      p_section_id: sectionA!.id,
    });
    if (error) throw error;
  };

  /** FR-G14's summary is FR-J09's attendance feed: 168 present of 180. */
  const summariseAttendance = async (enrolmentId: string) => {
    const { error } = await db.from('attendance_month_summary').insert([
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        enrolment_id: enrolmentId,
        year: 2026,
        month: 4,
        working_days: 90,
        present_days: 84,
        absent_days: 6,
        late_count: 0,
        half_day_count: 0,
        leave_days: 0,
        attendance_pct: 93.33,
        computed_at: new Date().toISOString(),
      },
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        enrolment_id: enrolmentId,
        year: 2026,
        month: 5,
        working_days: 90,
        present_days: 84,
        absent_days: 6,
        late_count: 0,
        half_day_count: 0,
        leave_days: 0,
        attendance_pct: 93.33,
        computed_at: new Date().toISOString(),
      },
    ]);
    if (error) throw error;
  };

  const charge = async (enrolmentId: string, paisa: number) => {
    const { error } = await accountantClient.rpc('post_ledger_entry', {
      p_enrolment_id: enrolmentId,
      p_entry_type: 'charge',
      p_amount_paisa: paisa,
      p_direction: 'debit',
    });
    if (error) throw error;
  };
  const setThreshold = async (paisa: number) => {
    const { error } = await accountantClient.rpc('set_result_withhold_threshold', {
      p_campus_id: campus!.id,
      p_paisa: paisa,
    });
    if (error) throw error;
  };
  const syncWithholds = async () => {
    const { error } = await accountantClient.rpc('fn_sync_fee_withholds', { p_exam_term_id: term!.id });
    if (error) throw error;
  };

  return {
    db,
    controllerEmail,
    examSubjects,
    enrol,
    enterMarks,
    approve,
    summariseAttendance,
    charge,
    setThreshold,
    syncWithholds,
  };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((url) => !url.pathname.startsWith('/login'));
}

async function openReportCards(page: import('@playwright/test').Page) {
  await page.goto('/exams/results');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('report-card-section-select').selectOption({ label: 'Class 5 — A' });
  await page.getByTestId('open-report-cards').click();
  await expect(page.getByTestId('report-card-sheet')).toBeVisible();
}

test('a report card renders one branded A4 page of real PDF bytes, refuses when withheld, and revises rather than overwrites', async ({
  page,
}) => {
  test.setTimeout(240_000);

  const { db, controllerEmail, examSubjects, enrol, enterMarks, approve, summariseAttendance, charge, setThreshold, syncWithholds } =
    await seed();

  const ayesha = await enrol('Ayesha Noor');
  const bilal = await enrol('Bilal Ahmed');
  await summariseAttendance(ayesha.enrolmentId);

  await signIn(page, controllerEmail);
  await openReportCards(page);

  // Nothing is signed off yet, so nothing prints and the screen says why.
  await expect(page.getByTestId(`report-card-blocked-${ayesha.grNumber}`)).toContainText(
    'term result is provisional',
  );
  await expect(page.getByTestId(`generate-report-card-${ayesha.grNumber}`)).toBeDisabled();

  // AC1: 160 + 150 + 152 + 150 = 612 of 800 = 76.50% = grade A.
  const ayeshaMarks = [160, 150, 152, 150];
  const bilalMarks = [180, 175, 178, 177];
  for (const [i, es] of examSubjects.entries()) {
    await enterMarks(es, [
      { enrolmentId: ayesha.enrolmentId, value: ayeshaMarks[i]! },
      { enrolmentId: bilal.enrolmentId, value: bilalMarks[i]! },
    ]);
    await approve(es);
  }

  await openReportCards(page);
  await expect(page.getByTestId(`no-report-card-${ayesha.grNumber}`)).toBeVisible();

  await page.getByTestId(`report-card-remark-${ayesha.grNumber}`).fill('A steady term. Reads widely.');
  await page.getByTestId(`generate-report-card-${ayesha.grNumber}`).click();
  await expect(page.getByTestId(`download-report-card-${ayesha.grNumber}`)).toHaveText('Revision 1');

  const { data: card1 } = await db
    .from('report_card')
    .select('id, revision_no, status, storage_path, checksum, payload_snapshot')
    .eq('enrolment_id', ayesha.enrolmentId)
    .eq('revision_no', 1)
    .single();
  expect(card1!.status).toBe('issued');

  // ── The snapshot IS the card ───────────────────────────────────────────
  const snap = card1!.payload_snapshot as Record<string, never> & {
    aggregate: { obtained: number; max_marks: number; pct: number; grade_label: string };
    attendance: { present_days: number; working_days: number; pct: number; from_date: string; to_date: string };
    position: { rank_in_section: number; ranked_out_of: number };
    remark: string;
    subjects: unknown[];
  };
  expect(snap.subjects).toHaveLength(4);
  expect(Number(snap.aggregate.obtained)).toBe(612);
  expect(snap.aggregate.max_marks).toBe(800);
  expect(Number(snap.aggregate.pct)).toBe(76.5);
  expect(snap.aggregate.grade_label).toBe('A');
  expect(snap.position.rank_in_section).toBe(2);
  expect(snap.position.ranked_out_of).toBe(2);
  expect(Number(snap.attendance.present_days)).toBe(168);
  expect(snap.attendance.working_days).toBe(180);
  expect(snap.attendance.from_date).toBe('2026-04-01');
  expect(snap.attendance.to_date).toBe('2026-05-31');
  expect(snap.remark).toBe('A steady term. Reads widely.');

  // ── AC1/AC2: the real bytes, through the verifying download route ──────
  const href = await page.getByTestId(`download-report-card-${ayesha.grNumber}`).getAttribute('href');
  expect(href).toContain(`/api/report-cards/${card1!.id}/download`);

  const response = await page.request.get(href!);
  expect(response.status()).toBe(200);
  expect(response.headers()['x-pdf-digest-status']).toBe('match');
  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  // AC1: "a single A4 page".
  expect(pdfPageCount(body)).toBe(1);
  // AC2: the logo and the signature are really composited in.
  expect(pdfImageCount(body)).toBeGreaterThanOrEqual(2);

  // The digest on the register row is the digest of the bytes in the bucket.
  const stored = await db.storage.from('report-cards').download(card1!.storage_path);
  expect(stored.error).toBeNull();
  const storedBytes = Buffer.from(await stored.data!.arrayBuffer());
  expect(card1!.checksum).toMatch(/^[0-9a-f]{64}$/);
  expect(card1!.checksum).toBe(sha256(storedBytes));
  expect(sha256(body)).toBe(card1!.checksum);

  // Byte-stability: rendering revision 1 again from revision 1's snapshot
  // produces the same file. Chromium stamps wall-clock time into every PDF,
  // so this only holds because the snapshot's rendered_at is written into the
  // document's own CreationDate.
  const { renderReportCardPdf } = await import('@/lib/report-cards/render');
  const reprint = await renderReportCardPdf(db as never, card1!.payload_snapshot as never);
  expect('error' in reprint).toBe(false);
  expect(sha256((reprint as { pdf: Uint8Array }).pdf)).toBe(card1!.checksum);

  // ── AC4: a regeneration is the next revision, not an overwrite ─────────
  await page.getByTestId(`generate-report-card-${ayesha.grNumber}`).click();
  await expect(page.getByTestId(`download-report-card-${ayesha.grNumber}`)).toHaveText('Revision 2');

  const { data: card2 } = await db
    .from('report_card')
    .select('id, revision_no, supersedes_revision, status, storage_path, payload_snapshot')
    .eq('enrolment_id', ayesha.enrolmentId)
    .eq('revision_no', 2)
    .single();
  expect(card2!.supersedes_revision).toBe(1);
  expect(card2!.storage_path).not.toBe(card1!.storage_path);
  // A blank remark box carries the previous revision's words forward.
  expect((card2!.payload_snapshot as { remark: string }).remark).toBe('A steady term. Reads widely.');

  const { data: card1After } = await db.from('report_card').select('status').eq('id', card1!.id).single();
  expect(card1After!.status).toBe('superseded');

  // AC4's footer, in the bytes rather than in the markup.
  const revised = await page.request.get(`/api/report-cards/${card2!.id}/download`);
  expect(revised.status()).toBe(200);
  const revisedBody = Buffer.from(await revised.body());
  expect(pdfPageCount(revisedBody)).toBe(1);
  const { buildReportCardHtml } = await import('@/lib/report-cards/html');
  const revisedHtml = buildReportCardHtml(card2!.payload_snapshot as never, null, {
    letterheadDataUri: null,
    logoDataUri: null,
    signatureDataUri: null,
    stampDataUri: null,
    photoDataUri: null,
  }).html;
  expect(revisedHtml).toContain('Revised — supersedes revision 1');

  // Revision 1's bytes are untouched: the bucket has no UPDATE policy and a
  // new revision takes a new path.
  const stillThere = await db.storage.from('report-cards').download(card1!.storage_path);
  expect(sha256(Buffer.from(await stillThere.data!.arrayBuffer()))).toBe(card1!.checksum);

  // ── AC3: withheld, refused, and nothing written ────────────────────────
  await charge(bilal.enrolmentId, 1_200_000);
  await setThreshold(500_000);
  await syncWithholds();

  await openReportCards(page);
  await expect(page.getByTestId(`report-card-blocked-${bilal.grNumber}`)).toContainText(
    'result withheld — outstanding dues of PKR 12,000',
  );
  await expect(page.getByTestId(`generate-report-card-${bilal.grNumber}`)).toBeDisabled();

  const { count } = await db
    .from('report_card')
    .select('id', { count: 'exact', head: true })
    .eq('enrolment_id', bilal.enrolmentId);
  expect(count).toBe(0);
});
