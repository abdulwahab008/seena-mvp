import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { createHash, randomUUID } from 'node:crypto';

// FR-J12: bulk report card generation, through the real UI and against the
// real bytes.
//
//   AC1  starting the batch shows a progress row immediately and the merged
//        file follows from the same action.
//   AC2  a withheld candidate and a candidate with no remark do not stop the
//        run: the rest are produced and those two are listed with their
//        reason codes.
//   AC3  the merged file is one PDF whose cards are in section-then-roll
//        order, each starting on its own SHEET — a one-page card is followed
//        by a blank side so duplex printing cannot put two children on one
//        piece of paper.
//   AC4  re-running after the remark is typed renders only that candidate and
//        rebuilds the merged file in full.
//
// Plus the property the ACs do not state and results day depends on: the
// individual cards are real, separately sealed documents at the same time as
// the merged one — a parent is handed theirs, the Principal prints the pile.
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

async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@batch-e2e.test`;
  const controllerEmail = `controller-${runId}@batch-e2e.test`;
  const accountantEmail = `accounts-${runId}@batch-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `batch-e2e-${runId}`,
    p_legal_name: `Batch E2E School ${runId}`,
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
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
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

  const withhold = async (enrolmentId: string) => {
    const { error: chargeError } = await accountantClient.rpc('post_ledger_entry', {
      p_enrolment_id: enrolmentId,
      p_entry_type: 'charge',
      p_amount_paisa: 1_200_000,
      p_direction: 'debit',
    });
    if (chargeError) throw chargeError;
    const { error: thresholdError } = await accountantClient.rpc('set_result_withhold_threshold', {
      p_campus_id: campus!.id,
      p_paisa: 500_000,
    });
    if (thresholdError) throw thresholdError;
    const { error: syncError } = await accountantClient.rpc('fn_sync_fee_withholds', { p_exam_term_id: term!.id });
    if (syncError) throw syncError;
  };

  return { db, controllerEmail, termId: term!.id as string, examSubjects, enrol, enterMarks, approve, withhold };
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

test('a whole section prints in one action, skips who it cannot print, and re-runs only them', async ({ page }) => {
  test.setTimeout(420_000);

  const { db, controllerEmail, termId, examSubjects, enrol, enterMarks, approve, withhold } = await seed();

  const ayesha = await enrol('Ayesha Noor');
  const bilal = await enrol('Bilal Ahmed');
  const chandni = await enrol('Chandni Rao');
  const danish = await enrol('Danish Ali');

  const marks: Record<string, number[]> = {
    [ayesha.enrolmentId]: [160, 150, 152, 150],
    [bilal.enrolmentId]: [180, 175, 178, 177],
    [chandni.enrolmentId]: [170, 165, 168, 167],
    [danish.enrolmentId]: [140, 135, 138, 137],
  };
  for (const [i, es] of examSubjects.entries()) {
    await enterMarks(
      es,
      Object.entries(marks).map(([enrolmentId, values]) => ({ enrolmentId, value: values[i]! })),
    );
    await approve(es);
  }

  // Chandni's dues put her over the campus threshold: FR-J08's hold, opened by
  // the sync exactly as it would be on results day.
  await withhold(chandni.enrolmentId);

  await signIn(page, controllerEmail);
  await openReportCards(page);

  // Two remarks typed, two left blank. Danish's blank box is AC2's second
  // reason code; Chandni's is beside the point, because she is withheld.
  await page.getByTestId(`report-card-remark-${ayesha.grNumber}`).fill('A steady term. Reads widely.');
  await page.getByTestId(`report-card-remark-${bilal.grNumber}`).fill('Leads the class in Maths.');

  // ── AC1/AC2: one action, and nobody stops the run ──────────────────────
  await page.getByTestId('start-report-card-batch').click();
  await expect(page.getByTestId('report-card-batch-progress')).toBeVisible();
  await expect(page.getByTestId('report-card-batch-counts')).toHaveText(
    '2 produced, 2 skipped, 0 failed, of 4',
    { timeout: 300_000 },
  );
  await expect(page.getByTestId('report-card-batch-status')).toHaveText('completed');

  // AC2's reason codes, per candidate, on the screen.
  await expect(page.getByTestId(`batch-skip-code-${chandni.grNumber}`)).toHaveText('Result withheld');
  await expect(page.getByTestId(`batch-skip-code-${danish.grNumber}`)).toHaveText('No remark');
  await expect(page.getByTestId(`batch-skip-${chandni.grNumber}`)).toContainText('outstanding dues of PKR 12,000');

  const { data: batch } = await db
    .from('report_card_batch')
    .select('id, status, total, succeeded, skipped, failed, file_path, checksum, page_count')
    .eq('exam_term_id', termId)
    .single();
  expect(batch!.status).toBe('completed');
  expect([batch!.total, batch!.succeeded, batch!.skipped, batch!.failed]).toEqual([4, 2, 2, 0]);
  expect(batch!.checksum).toMatch(/^[0-9a-f]{64}$/);

  // Every candidate is accounted for — a batch never silently omits one.
  const { data: items } = await db
    .from('report_card_batch_item')
    .select('enrolment_id, seq, status, error_code, page_count')
    .eq('batch_id', batch!.id)
    .order('seq');
  expect(items).toHaveLength(4);
  expect(items!.map((i) => i.enrolment_id)).toEqual([
    ayesha.enrolmentId,
    bilal.enrolmentId,
    chandni.enrolmentId,
    danish.enrolmentId,
  ]);
  expect(items!.map((i) => i.status)).toEqual(['succeeded', 'succeeded', 'skipped', 'skipped']);
  expect(items!.map((i) => i.error_code)).toEqual([null, null, 'result_withheld', 'remark_missing']);

  // ── AC3: the merged file, in real bytes ────────────────────────────────
  const mergedHref = await page.getByTestId('download-report-card-batch').getAttribute('href');
  expect(mergedHref).toContain(`/api/report-cards/batches/${batch!.id}/download`);

  const merged = await page.request.get(mergedHref!);
  expect(merged.status()).toBe(200);
  expect(merged.headers()['x-pdf-digest-status']).toBe('match');
  const mergedBody = Buffer.from(await merged.body());
  expect(mergedBody.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(sha256(mergedBody)).toBe(batch!.checksum);

  // Two one-page cards, each padded to a whole SHEET: 1 + blank + 1 = three
  // sides, and the last card takes no filler because nothing follows it onto
  // its back. Anything less and duplex printing mixes two students.
  expect(items!.map((i) => i.page_count)).toEqual([1, 1, null, null]);
  expect(pdfPageCount(mergedBody)).toBe(3);
  expect(batch!.page_count).toBe(3);

  // ── and the individual cards exist at the same time ────────────────────
  const { data: cards } = await db
    .from('report_card')
    .select('id, enrolment_id, revision_no, status, checksum')
    .eq('exam_term_id', termId)
    .order('revision_no');
  expect(cards).toHaveLength(2);
  expect(cards!.every((c) => c.status === 'issued')).toBe(true);

  const single = await page.request.get(`/api/report-cards/${cards![0]!.id}/download`);
  expect(single.status()).toBe(200);
  const singleBody = Buffer.from(await single.body());
  expect(pdfPageCount(singleBody)).toBe(1);
  expect(sha256(singleBody)).toBe(cards![0]!.checksum);
  // The parent's copy is not the Principal's pile.
  expect(sha256(singleBody)).not.toBe(batch!.checksum);

  // ── AC4: fix the remark, re-run, and only that candidate renders ───────
  await page.getByTestId(`report-card-remark-${danish.grNumber}`).fill('Much improved in Science.');
  await page.getByTestId('retry-report-card-batch').click();
  await expect(page.getByTestId('report-card-batch-counts')).toHaveText(
    '3 produced, 1 skipped, 0 failed, of 4',
    { timeout: 300_000 },
  );

  const { data: afterItems } = await db
    .from('report_card_batch_item')
    .select('enrolment_id, status, attempts, error_code')
    .eq('batch_id', batch!.id)
    .order('seq');
  // The two that were already right were claimed exactly once across both runs.
  expect(afterItems!.slice(0, 2).map((i) => i.attempts)).toEqual([1, 1]);
  expect(afterItems!.map((i) => i.status)).toEqual(['succeeded', 'succeeded', 'skipped', 'succeeded']);
  expect(afterItems![2]!.error_code).toBe('result_withheld');

  // Nobody was re-rendered: every card is still its first revision.
  const { data: cardsAfter } = await db
    .from('report_card')
    .select('enrolment_id, revision_no, status')
    .eq('exam_term_id', termId);
  expect(cardsAfter).toHaveLength(3);
  expect(cardsAfter!.every((c) => c.revision_no === 1 && c.status === 'issued')).toBe(true);

  // The merged file is rebuilt IN FULL — three cards, three sheets — and at
  // the same path, so the link a Principal already has still resolves.
  const { data: batchAfter } = await db
    .from('report_card_batch')
    .select('file_path, checksum, page_count')
    .eq('id', batch!.id)
    .single();
  expect(batchAfter!.file_path).toBe(batch!.file_path);
  expect(batchAfter!.checksum).not.toBe(batch!.checksum);
  expect(batchAfter!.page_count).toBe(5);

  const rebuilt = await page.request.get(mergedHref!);
  expect(rebuilt.status()).toBe(200);
  const rebuiltBody = Buffer.from(await rebuilt.body());
  expect(pdfPageCount(rebuiltBody)).toBe(5);
  expect(sha256(rebuiltBody)).toBe(batchAfter!.checksum);
});
