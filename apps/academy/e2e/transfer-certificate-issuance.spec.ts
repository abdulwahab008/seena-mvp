import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T03: a Transfer Certificate issued through the real UI by a real
// Admissions Officer. Every assertion is made against what actually
// happened rather than what the page said: the PDF is fetched from the
// private bucket and its bytes and paper size are read out of the file, the
// serial is read off FR-T02's counter, and the enrolment transition is read
// off the row. The AC2 rejection is the SERVER's, and the serial it names is
// compared to the one that was really allocated.
//
// Same posture as e2e/certificate-template-designer.spec.ts, whose renderer
// and template machinery this builds on.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

/** A4 portrait in PDF points (1pt = 1/72in), rounded. */
const A4_PORTRAIT_WIDTH_PT = 595;

const TC_BODY =
  '<p>This is to certify that {{student.name_en}}, GR No. {{student.gr_number}}, born {{student.dob}} ' +
  '({{student.dob_words}}), of {{enrolment.class_name}} {{enrolment.section_name}}, left this institution on ' +
  '{{enrolment.left_on}}. Conduct: {{transfer.conduct}}. Reason: {{transfer.reason}}. ' +
  'Serial No. {{issue.serial_no}}, issued {{issue.date}}.</p>';

function pdfFirstMediaBox(body: Buffer): { width: number; height: number } {
  const match = body.toString('latin1').match(/\/MediaBox\s*\[\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)\s*\]/);
  if (!match) throw new Error('no MediaBox in the produced PDF');
  return { width: Math.round(Number(match[1])), height: Math.round(Number(match[2])) };
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@certissue-e2e.test`;
  const clerkEmail = `clerk-${runId}@certissue-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `certissue-e2e-${runId}`,
    p_legal_name: `Cert Issue E2E School ${runId}`,
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

  const { data: section, error: sectionError } = await admin
    .from('class_section')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      name: 'A',
      capacity: 40,
    })
    .select('id')
    .single();
  if (sectionError || !section) throw sectionError ?? new Error('section creation failed');

  // Students, enrolments and the template all go through a SIGNED-IN
  // client: those RPCs read JWT role/campus claims a service-role call
  // never carries, and enrolment's fee-plan trigger looks the new row up by
  // app.auth_tenant_id(). Same convention as
  // e2e/session-rollover-and-promotion.spec.ts.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  // AC3's date of birth. Two more students so the issuing form stays on
  // screen after the first certificate takes its student off the list.
  const cohort = [
    { name: 'Ali Raza', dob: '2011-03-04', gender: 'male' as const },
    { name: 'Zoya Sheikh', dob: '2012-07-21', gender: 'female' as const },
    { name: 'Hamza Iqbal', dob: '2012-01-09', gender: 'male' as const },
  ];
  const studentIds: string[] = [];
  for (const s of cohort) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
      p_gender: s.gender,
      p_father_name_en: 'Muhammad Raza',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    studentIds.push(studentId as string);
    const { error: enrolError } = await ownerClient.rpc('enrol_student', { p_section_id: section.id, p_student_id: studentId as string });
    if (enrolError) throw enrolError;
  }

  const { data: templateId, error: templateError } = await ownerClient.rpc('create_certificate_template', {
    p_certificate_type: 'transfer',
    p_title: 'School Leaving Certificate',
    p_body_html: TC_BODY,
    p_board_code: 'FBISE',
    p_language: 'en',
    p_page_size: 'A4',
    p_campus_id: campus!.id,
  });
  if (templateError || !templateId) throw templateError ?? new Error('template creation failed');
  const { error: activateError } = await ownerClient.rpc('activate_certificate_template', { p_template_id: templateId as string });
  if (activateError) throw activateError;

  const { data: ali } = await admin.from('student').select('id, gr_number').eq('id', studentIds[0]!).single();

  return {
    admin,
    clerkEmail,
    tenantId: tenantId as string,
    campusId: campus!.id as string,
    sessionId: session!.id as string,
    aliId: ali!.id as string,
    aliGr: ali!.gr_number as string,
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

test('an Admissions Officer issues a Transfer Certificate, and a second one is refused by serial', async ({ page }) => {
  const { admin, clerkEmail, tenantId, campusId, sessionId, aliId, aliGr } = await seed();
  const today = new Date().toISOString().slice(0, 10);

  await signIn(page, clerkEmail);
  await page.goto('/certificates/issue');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Issue a Transfer Certificate' })).toBeVisible();
  await expect(page.getByTestId('cert-issue-register-empty')).toBeVisible();

  // ── AC1: issue the certificate ────────────────────────────────────────
  await page.getByTestId('cert-issue-student-trigger').click();
  await page.getByTestId(`cert-issue-student-${aliGr}`).click();
  await page.getByTestId('cert-issue-template-trigger').click();
  await page.getByTestId('cert-issue-template-FBISE-en').click();
  await page.getByTestId('cert-issue-leaving-date').fill(today);
  await page.getByTestId('cert-issue-conduct').fill('Good');
  await page.getByTestId('cert-issue-reason').fill('Family relocation');
  await page.getByTestId('cert-issue-submit').click();

  const result = page.getByTestId('cert-issue-result');
  await expect(result).toBeVisible({ timeout: 60_000 });

  const year = new Date().getFullYear();
  const expectedSerial = `TC-${year}-000001`;
  await expect(result).toContainText(expectedSerial);

  // ── AC1: real PDF bytes, in the private bucket, on A4 ─────────────────
  const href = await page.getByTestId('cert-issue-download-link').getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);
  const response = await page.request.get(href!);
  expect(response.ok()).toBe(true);
  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(body.length).toBeGreaterThan(1000);
  expect(pdfFirstMediaBox(body).width).toBe(A4_PORTRAIT_WIDTH_PT);

  // The same object, read back off the bucket rather than off a link the
  // page handed us.
  const { data: issueRow } = await admin
    .from('certificate_issue')
    .select('id, serial_no, status, pdf_path, template_version, payload_snapshot')
    .eq('student_id', aliId)
    .single();
  expect(issueRow!.serial_no).toBe(expectedSerial);
  expect(issueRow!.status).toBe('issued');
  expect(issueRow!.pdf_path).toBe(`${tenantId}/${campusId}/transfer/${expectedSerial}.pdf`);
  const stored = await admin.storage.from('certificates').download(issueRow!.pdf_path);
  expect(stored.error).toBeNull();
  const storedBytes = Buffer.from(await stored.data!.arrayBuffer());
  expect(storedBytes.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(storedBytes.length).toBe(body.length);

  // AC3: the words of the date of birth are frozen onto the document that
  // was printed, alongside the figure form.
  const values = (issueRow!.payload_snapshot as { values: Record<string, string> }).values;
  expect(values['student.dob']).toBe('04-03-2011');
  expect(values['student.dob_words']).toBe('Fourth March Two Thousand Eleven');
  expect(values['issue.serial_no']).toBe(expectedSerial);
  expect(values['transfer.conduct']).toBe('Good');

  // ── AC1: the enrolment transitioned, and the serial was really taken ──
  const { data: enrolment } = await admin
    .from('enrolment')
    .select('status, left_on, tc_issued_at, tc_certificate_issue_id')
    .eq('student_id', aliId)
    .single();
  expect(enrolment!.status).toBe('transferred');
  expect(enrolment!.left_on).toBe(today);
  expect(enrolment!.tc_issued_at).not.toBeNull();
  expect(enrolment!.tc_certificate_issue_id).toBe(issueRow!.id);

  const { data: counter } = await admin
    .from('certificate_serial_counter')
    .select('current_value')
    .eq('campus_id', campusId)
    .eq('certificate_type', 'transfer')
    .eq('session_id', sessionId)
    .single();
  expect(Number(counter!.current_value)).toBe(1);

  // The bucket is private: no unauthenticated read of a statutory document.
  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const anonRead = await anon.storage.from('certificates').download(issueRow!.pdf_path);
  expect(anonRead.error).not.toBeNull();

  // ── AC2: a second original, refused by name ───────────────────────────
  // The form is still holding the student it just issued for — a stale tab,
  // a double click or a second clerk all arrive at the server the same way,
  // and the server is what has to refuse it.
  await page.getByTestId('cert-issue-submit').click();
  const issueError = page.getByTestId('cert-issue-error');
  await expect(issueError).toBeVisible({ timeout: 60_000 });
  await expect(issueError).toContainText(`TC already issued, serial ${expectedSerial}`);
  await expect(issueError).toContainText('use Duplicate instead');

  // The refusal happened before the allocator, so no number was burnt.
  const { data: counterAfter } = await admin
    .from('certificate_serial_counter')
    .select('current_value')
    .eq('campus_id', campusId)
    .eq('certificate_type', 'transfer')
    .eq('session_id', sessionId)
    .single();
  expect(Number(counterAfter!.current_value)).toBe(1);

  const { count } = await admin
    .from('certificate_issue')
    .select('id', { count: 'exact', head: true })
    .eq('student_id', aliId);
  expect(count).toBe(1);
});
