import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I17: break-glass mark unlock, through the real UI.
//
//   AC1  the Exam Controller requests an unlock on locked 9-B Maths with a
//        written reason; the marks stay locked until a Principal approves, and
//        the Principal cannot approve one they raised themselves.
//   AC2  approved with a window: the grid becomes writable, and once the clock
//        is past the deadline the scheduled job re-locks it and further edits
//        fail.
//   AC3  an edit inside the window leaves an audit row with old value, new
//        value, actor and unlock request id, and the section's result is
//        marked stale.
//   AC4  three unlocks on the same paper put it in the Owner's exceptions
//        report with its reasons and approvers.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * Class 9-B sitting one Maths paper, marked and SIGNED OFF — a break-glass
 * unlock has nothing to work on until FR-I16's lock is in place, so the seed
 * ends with fn_approve_marks() rather than with the marks.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@break-glass-e2e.test`;
  const controllerEmail = `controller-${runId}@break-glass-e2e.test`;
  const principalEmail = `principal-${runId}@break-glass-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `break-glass-e2e-${runId}`,
    p_legal_name: `Break Glass E2E School ${runId}`,
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
  const controllerId = await makeUser(controllerEmail, 'exam_controller', 'Rukhsana Bano');
  await makeUser(principalEmail, 'principal', 'Farhan Qureshi');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);

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

  const enrolments: string[] = [];
  for (const [i, s] of [
    { name: 'Ali Raza', dob: '2011-03-04' },
    { name: 'Zoya Sheikh', dob: '2011-07-21' },
  ].entries()) {
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
    enrolments.push(enrolment!.id);
  }

  const { error: markError } = await controllerClient.rpc('fn_upsert_marks', {
    p_payload: {
      exam_subject_id: examSubject,
      marks: enrolments.map((id, i) => ({
        enrolment_id: id,
        component: 'theory',
        marks_obtained: 41 + i,
      })),
    },
  });
  if (markError) throw markError;

  const { error: approveError } = await controllerClient.rpc('fn_approve_marks', {
    p_exam_subject_id: examSubject,
    p_section_id: section!.id,
  });
  if (approveError) throw approveError;

  return {
    ownerEmail,
    controllerEmail,
    principalEmail,
    controllerId,
    examSubject,
    sectionId: section!.id,
    termId: term!.id,
    enrolments,
    controllerClient,
  };
}

/**
 * The two-person control means this spec signs in three times in one test —
 * more than any other in the suite — and the local GoTrue container
 * intermittently drops a request under parallel load. One retry, because a
 * flaky sign-in is not what this test is about and a spurious failure here
 * would read as a broken lock.
 */
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

async function openApprovalBoard(page: import('@playwright/test').Page) {
  await page.goto('/exams/approvals');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('approval-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('open-approval-queue').click();
  await expect(page.getByTestId('approval-queue')).toBeVisible();
}

async function openGrid(page: import('@playwright/test').Page) {
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — B' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Maths' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
}

test('a controller raises a break-glass request, a Principal grants it, the correction is audited, and the clock closes it', async ({
  page,
}) => {
  const { controllerEmail, principalEmail, examSubject, sectionId, termId, enrolments } = await seed();
  const db = admin();

  // ── AC1: the request ───────────────────────────────────────────────────
  await signIn(page, controllerEmail);
  await openApprovalBoard(page);
  await expect(page.getByTestId('approval-locked-Maths')).toBeVisible();

  // A reason under ten characters does not even arm the button.
  await page.getByTestId('request-unlock-reason-Maths').fill('oops');
  await expect(page.getByTestId('request-unlock-Maths')).toBeDisabled();
  await page.getByTestId('request-unlock-reason-Maths').fill('Q5 total mis-added on 6 scripts');
  await expect(page.getByTestId('request-unlock-Maths')).toBeEnabled();
  await page.getByTestId('request-unlock-Maths').click();
  // The reason field clears on success, which re-disables the button.
  await expect(page.getByTestId('request-unlock-Maths')).toBeDisabled();
  await expect
    .poll(async () => {
      const { count } = await db
        .from('mark_unlock_request')
        .select('id', { count: 'exact', head: true })
        .eq('exam_subject_id', examSubject);
      return count ?? 0;
    })
    .toBe(1);

  const { data: requests } = await db
    .from('mark_unlock_request')
    .select('id, status, reason, approved_by, expires_at')
    .eq('exam_subject_id', examSubject);
  expect(requests!.length).toBe(1);
  const requestId = requests![0]!.id;
  expect(requests![0]!.status).toBe('pending');
  expect(requests![0]!.reason).toBe('Q5 total mis-added on 6 scripts');

  // AC1: "the marks stay locked until a Principal approves".
  await openGrid(page);
  await expect(page.getByTestId('mark-entry-locked')).toBeVisible();
  await expect(page.getByTestId('mark-cell-1-theory')).toBeDisabled();

  // The controller can see their request but cannot decide it.
  await page.goto('/exams/unlocks');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`unlock-reason-${requestId}`)).toContainText('Q5 total mis-added on 6 scripts');
  await expect(page.getByTestId(`unlock-approve-${requestId}`)).toHaveCount(0);

  // ── AC1: a Principal grants it, and cannot grant their own ─────────────
  await page.context().clearCookies();
  await signIn(page, principalEmail);
  await page.goto('/exams/unlocks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId(`unlock-window-${requestId}`).fill('45');
  await page.getByTestId(`unlock-approve-${requestId}`).click();
  await expect(page.getByTestId(`unlock-open-${requestId}`)).toBeVisible();

  const { data: granted } = await db
    .from('mark_unlock_request')
    .select('status, approved_by, approved_at, expires_at')
    .eq('id', requestId)
    .single();
  expect(granted!.status).toBe('approved');
  expect(granted!.approved_by).not.toBeNull();
  expect(new Date(granted!.expires_at!).getTime() - new Date(granted!.approved_at!).getTime()).toBe(45 * 60_000);

  // The alert a Principal actually reads, not just an audit_log row.
  const { data: alerts } = await db
    .from('security_event')
    .select('event_type, severity, detail')
    .eq('subject_id', requestId);
  expect(alerts!.length).toBe(1);
  expect(alerts![0]!.event_type).toBe('mark_break_glass_unlock');
  expect(alerts![0]!.severity).toBe('alert');

  // ── AC3: the correction, inside the window ─────────────────────────────
  await page.context().clearCookies();
  await signIn(page, controllerEmail);
  await openGrid(page);
  await expect(page.getByTestId('mark-entry-break-glass')).toContainText('Break-glass window open');
  await expect(page.getByTestId('mark-entry-break-glass')).toContainText('Q5 total mis-added on 6 scripts');
  await expect(page.getByTestId('mark-entry-locked')).toHaveCount(0);

  const theory1 = page.getByTestId('mark-cell-1-theory');
  await expect(theory1).toBeEnabled();
  await expect(theory1).toHaveValue('41');
  await theory1.fill('47');
  await theory1.blur();
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText(/^Saved/, { timeout: 5000 });

  await expect
    .poll(async () => {
      const { count } = await db
        .from('mark_entry_audit')
        .select('id', { count: 'exact', head: true })
        .eq('mark_unlock_request_id', requestId);
      return count ?? 0;
    })
    .toBe(1);
  const { data: trail } = await db
    .from('mark_entry_audit')
    .select('old_marks, new_marks, actor_user_id, action, mark_unlock_request_id')
    .eq('mark_unlock_request_id', requestId)
    .single();
  expect(Number(trail!.old_marks)).toBe(41);
  expect(Number(trail!.new_marks)).toBe(47);
  expect(trail!.action).toBe('update');
  expect(trail!.actor_user_id).not.toBeNull();

  // "every affected report card is marked stale"
  const { data: lock } = await db
    .from('mark_lock')
    .select('result_stale_at, result_stale_request_id, unlock_state')
    .eq('exam_subject_id', examSubject)
    .single();
  expect(lock!.result_stale_at).not.toBeNull();
  expect(lock!.result_stale_request_id).toBe(requestId);
  expect(lock!.unlock_state).toBe('unlocked');

  // ── AC2: the clock passes the deadline ─────────────────────────────────
  const { data: relocked } = await db.rpc('fn_relock_expired_unlocks', {
    p_as_of: new Date(Date.now() + 46 * 60_000).toISOString(),
  });
  expect(relocked).toBe(1);

  const { data: closed } = await db
    .from('mark_unlock_request')
    .select('status, relocked_at')
    .eq('id', requestId)
    .single();
  expect(closed!.status).toBe('expired');
  expect(closed!.relocked_at).not.toBeNull();

  // "with the browser tab still open" — the page has not been reloaded, and
  // the write is refused all the same.
  await theory1.fill('12');
  await theory1.blur();
  await expect(page.getByTestId('mark-entry-save-status')).toHaveText('Not saved', { timeout: 5000 });
  const { data: unchanged } = await db
    .from('mark_entry')
    .select('marks_obtained')
    .eq('exam_subject_id', examSubject)
    .eq('enrolment_id', enrolments[0]!)
    .single();
  expect(Number(unchanged!.marks_obtained)).toBe(47);

  // And on the next load the grid is read-only again.
  await openGrid(page);
  await expect(page.getByTestId('mark-entry-break-glass')).toHaveCount(0);
  await expect(page.getByTestId('mark-entry-locked')).toBeVisible();
  await expect(page.getByTestId('mark-cell-1-theory')).toBeDisabled();

  // The result gate FR-J02 asks still says computable, and now also stale.
  const { data: ready } = await db.rpc('fn_term_result_ready', {
    p_exam_term_id: termId,
    p_section_id: sectionId,
  });
  expect((ready as { ready: boolean; stale: boolean }).ready).toBe(true);
  expect((ready as { ready: boolean; stale: boolean }).stale).toBe(true);
});

test('three unlocks on one paper put it in the Owner’s exceptions report with its reasons and approvers', async ({
  page,
}) => {
  const { ownerEmail, principalEmail, examSubject, sectionId, controllerClient } = await seed();
  const db = admin();

  const principalClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await principalClient.auth.signInWithPassword({ email: principalEmail, password: PASSWORD });

  // Three complete cycles: raised by the controller, granted by the Principal,
  // closed by the sweep. Driven through the RPCs rather than the screens —
  // the first test already covers the screens, and this one is about what the
  // report shows after three of them.
  const reasons = [
    'Q5 total mis-added on 6 scripts',
    'Practical sheet swapped between two candidates',
    'Board erratum on question 11 applied late',
  ];
  for (const reason of reasons) {
    const { data: requestId, error: reqError } = await controllerClient.rpc('request_mark_unlock', {
      p_exam_subject_id: examSubject,
      p_section_id: sectionId,
      p_reason: reason,
    });
    if (reqError) throw reqError;
    const { error: grantError } = await principalClient.rpc('fn_break_glass_unlock', {
      p_request_id: requestId as string,
      p_window_minutes: 15,
    });
    if (grantError) throw grantError;
    const { error: sweepError } = await db.rpc('fn_relock_expired_unlocks', {
      p_as_of: new Date(Date.now() + 16 * 60_000).toISOString(),
    });
    if (sweepError) throw sweepError;
  }

  await signIn(page, ownerEmail);
  await page.goto('/exams/unlocks');
  await page.waitForLoadState('networkidle');

  await expect(page.getByTestId('unlock-count-Maths')).toHaveText('3 unlocks');
  for (const reason of reasons) {
    await expect(page.getByTestId('unlock-reasons-Maths')).toContainText(reason);
  }
  await expect(page.getByTestId('unlock-approvers-Maths')).toContainText('Farhan Qureshi');
  await expect(page.getByTestId('unlock-approvers-Maths')).toContainText('Rukhsana Bano');
  await expect(page.getByTestId('unlock-no-open')).toBeVisible();
});
