import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T05: a Character Certificate issued through the real UI by a real
// Admissions Officer, for a student who PASSED OUT three years ago. Every
// assertion is made against what actually happened rather than what the page
// said: the PDF is fetched from the private bucket and its bytes are read out
// of the file, the serial is read off FR-T02's counter, and the attendance
// period is compared against the enrolment history that produced it.
//
// Same posture as e2e/transfer-certificate-issuance.spec.ts, whose issuing
// machinery this shares.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

/** A4 portrait in PDF points (1pt = 1/72in), rounded. */
const A4_PORTRAIT_WIDTH_PT = 595;

// AC1's span, exactly: five sessions running April to March.
const FIRST_SESSION_YEAR = 2018;
const LAST_SESSION_YEAR = 2022;
const PERIOD_FROM = `${FIRST_SESSION_YEAR}-04-01`;
const PERIOD_TO = `${LAST_SESSION_YEAR + 1}-03-31`;

const CC_BODY =
  '<p>Certified that {{student.name_en}}, GR No. {{student.gr_number}}, was a student of this institution ' +
  'from {{character.period_from}} to {{character.period_to}} and that his conduct during that period was ' +
  '{{character.conduct_grade}}. {{character.remarks}} Serial No. {{issue.serial_no}}, issued {{issue.date}}.</p>';

function pdfFirstMediaBox(body: Buffer): { width: number; height: number } {
  const match = body.toString('latin1').match(/\/MediaBox\s*\[\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)\s*\]/);
  if (!match) throw new Error('no MediaBox in the produced PDF');
  return { width: Math.round(Number(match[1])), height: Math.round(Number(match[2])) };
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@charcert-e2e.test`;
  const clerkEmail = `clerk-${runId}@charcert-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `charcert-e2e-${runId}`,
    p_legal_name: `Character Cert E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (error) throw error;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const makeUser = async (email: string, role: 'owner' | 'admissions_officer', fullName: string) => {
    const { data: created, error: userError } = await admin.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (userError || !created.user) throw userError ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await admin
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: role, full_name: fullName });
    if (appUserError) throw appUserError;
    const { error: campusError } = await admin
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
    if (campusError) throw campusError;
  };
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  await makeUser(clerkEmail, 'admissions_officer', 'Farhat Jabeen');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
    p_campus_id: campus!.id,
    p_name_en: 'Ali Raza',
    p_dob: '2007-06-15',
    p_gender: 'male',
    p_father_name_en: 'Muhammad Raza',
  });
  if (studentError || !studentId) throw studentError ?? new Error('student creation failed');

  // The history AC1 is about: one enrolment per session (FR-A06's rollover
  // shape), every left_on null, the student long since passed out.
  //
  // The sessions and sections are written with the service role (no RPC
  // opens a closed year), but the ENROLMENTS go through enrol_student() as
  // the signed-in Owner: enrolment's fee-plan trigger looks the new row up
  // by app.auth_tenant_id(), which a service-role call never carries. Their
  // dates are then corrected with the service role, which is an UPDATE and
  // fires no such trigger.
  for (let year = FIRST_SESSION_YEAR; year <= LAST_SESSION_YEAR; year += 1) {
    const { data: pastSession, error: sessionError } = await admin
      .from('academic_session')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        name: `${year}-${String(year + 1).slice(2)}`,
        starts_on: `${year}-04-01`,
        ends_on: `${year + 1}-03-31`,
        is_current: false,
        status: 'closed',
      })
      .select('id')
      .single();
    if (sessionError || !pastSession) throw sessionError ?? new Error('session creation failed');

    const { data: pastSection, error: sectionError } = await admin
      .from('class_section')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: pastSession.id,
        class_level_id: classLevel!.id,
        name: 'A',
        capacity: 40,
      })
      .select('id')
      .single();
    if (sectionError || !pastSection) throw sectionError ?? new Error('section creation failed');

    const { error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: pastSection.id,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;

    const { error: dateError } = await admin
      .from('enrolment')
      .update({ joined_on: `${year}-04-01`, status: 'graduated' })
      .eq('student_id', studentId as string)
      .eq('session_id', pastSession.id);
    if (dateError) throw dateError;
  }
  const { error: passedOutError } = await admin
    .from('student')
    .update({ status: 'passed_out' })
    .eq('id', studentId as string);
  if (passedOutError) throw passedOutError;

  const { data: templateId, error: templateError } = await ownerClient.rpc('create_certificate_template', {
    p_certificate_type: 'character',
    p_title: 'Character Certificate',
    p_body_html: CC_BODY,
    p_language: 'en',
    p_page_size: 'A4',
    p_campus_id: campus!.id,
  });
  if (templateError || !templateId) throw templateError ?? new Error('template creation failed');
  const { error: activateError } = await ownerClient.rpc('activate_certificate_template', { p_template_id: templateId as string });
  if (activateError) throw activateError;

  // AC3: the campus transfer series is already deep into the year. Walked up
  // with the service role because FR-T02 grants the allocator to nobody else.
  for (let i = 0; i < 147; i += 1) {
    const { error: allocError } = await admin.rpc('allocate_certificate_serial', {
      p_campus_id: campus!.id,
      p_certificate_type: 'transfer',
      p_session_id: session!.id,
    });
    if (allocError) throw allocError;
  }

  const { data: student } = await admin.from('student').select('id, gr_number').eq('id', studentId as string).single();

  return {
    admin,
    clerkEmail,
    tenantId: tenantId as string,
    campusId: campus!.id as string,
    sessionId: session!.id as string,
    studentId: student!.id as string,
    studentGr: student!.gr_number as string,
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

test('a Character Certificate is issued to a passed-out student, on its own series, more than once', async ({ page }) => {
  const { admin, clerkEmail, tenantId, campusId, sessionId, studentId, studentGr } = await seed();
  const year = new Date().getFullYear();

  await signIn(page, clerkEmail);
  await page.goto('/certificates/issue/character');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Issue a Character Certificate' })).toBeVisible();
  await expect(page.getByTestId('cc-issue-register-empty')).toBeVisible();

  // ── AC1: the period the school actually has on record, shown up front ──
  await page.getByTestId('cc-issue-student-trigger').click();
  await page.getByTestId(`cc-issue-student-${studentGr}`).click();
  const derived = page.getByTestId('cc-issue-derived-period');
  await expect(derived).toBeVisible({ timeout: 30_000 });
  await expect(derived).toContainText('01-04-2018 to 31-03-2023');
  await expect(derived).toContainText('5 enrolments on record');

  await page.getByTestId('cc-issue-template-trigger').click();
  await page.getByTestId('cc-issue-template-any-en').click();
  await page.getByTestId('cc-issue-conduct-trigger').click();
  await page.getByTestId('cc-issue-conduct-Very-Good').click();
  await page.getByTestId('cc-issue-remarks').fill('Bore an excellent character throughout.');
  // Both period fields deliberately left blank: the database derives them.
  await page.getByTestId('cc-issue-submit').click();

  const result = page.getByTestId('cc-issue-result');
  await expect(result).toBeVisible({ timeout: 60_000 });

  // ── AC3: an independent series, while transfers sit at 147 ─────────────
  const expectedSerial = `CC-${year}-000001`;
  await expect(result).toContainText(expectedSerial);
  await expect(result).toContainText('01-04-2018 to 31-03-2023');

  const { data: counters } = await admin
    .from('certificate_serial_counter')
    .select('certificate_type, current_value')
    .eq('campus_id', campusId)
    .eq('session_id', sessionId);
  const byType = new Map((counters ?? []).map((c) => [c.certificate_type, Number(c.current_value)]));
  expect(byType.get('transfer')).toBe(147);
  expect(byType.get('character')).toBe(1);

  // ── AC1: real PDF bytes, in the private bucket, on A4 ──────────────────
  const href = await page.getByTestId('cc-issue-download-link').getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);
  const response = await page.request.get(href!);
  expect(response.ok()).toBe(true);
  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(body.length).toBeGreaterThan(1000);
  expect(pdfFirstMediaBox(body).width).toBe(A4_PORTRAIT_WIDTH_PT);

  const { data: issueRow } = await admin
    .from('certificate_issue')
    .select('id, serial_no, status, pdf_path, session_id, payload_snapshot')
    .eq('student_id', studentId)
    .single();
  expect(issueRow!.serial_no).toBe(expectedSerial);
  expect(issueRow!.status).toBe('issued');
  expect(issueRow!.pdf_path).toBe(`${tenantId}/${campusId}/character/${expectedSerial}.pdf`);
  // The serial belongs to the year the register page was written in, not to
  // the session the student attended.
  expect(issueRow!.session_id).toBe(sessionId);

  const stored = await admin.storage.from('certificates').download(issueRow!.pdf_path);
  expect(stored.error).toBeNull();
  const storedBytes = Buffer.from(await stored.data!.arrayBuffer());
  expect(storedBytes.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(storedBytes.length).toBe(body.length);

  // AC1 + AC2: what the document actually says, frozen at issue.
  const values = (issueRow!.payload_snapshot as { values: Record<string, string> }).values;
  expect(values['character.period_from']).toBe('01-04-2018');
  expect(values['character.period_to']).toBe('31-03-2023');
  expect(values['character.conduct_grade']).toBe('Very Good');
  expect(values['issue.serial_no']).toBe(expectedSerial);
  // The period really did come from the enrolment rows, not from a constant.
  const { data: enrolments } = await admin
    .from('enrolment')
    .select('joined_on')
    .eq('student_id', studentId)
    .order('joined_on');
  expect(enrolments).toHaveLength(5);
  expect(enrolments![0]!.joined_on).toBe(PERIOD_FROM);
  const { data: lastSession } = await admin
    .from('academic_session')
    .select('ends_on')
    .eq('tenant_id', tenantId)
    .eq('name', `${LAST_SESSION_YEAR}-${String(LAST_SESSION_YEAR + 1).slice(2)}`)
    .single();
  expect(lastSession!.ends_on).toBe(PERIOD_TO);

  // The bucket is private: no unauthenticated read of a statutory document.
  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const anonRead = await anon.storage.from('certificates').download(issueRow!.pdf_path);
  expect(anonRead.error).not.toBeNull();

  // ── AC4: a second one for the same student simply succeeds ─────────────
  await page.getByTestId('cc-issue-submit').click();
  await expect(page.getByTestId('cc-issue-result')).toContainText(`CC-${year}-000002`, { timeout: 60_000 });
  await expect(page.getByTestId('cc-issue-error')).toHaveCount(0);

  const { count } = await admin
    .from('certificate_issue')
    .select('id', { count: 'exact', head: true })
    .eq('student_id', studentId)
    .eq('certificate_type', 'character')
    .eq('status', 'issued');
  expect(count).toBe(2);

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`cc-issue-row-${expectedSerial}`)).toContainText('Very Good');
  await expect(page.getByTestId(`cc-issue-row-${expectedSerial}`)).toContainText('01-04-2018');
});
