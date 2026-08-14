import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T08: the bound-register equivalent, driven end to end through the real
// UI by a real Principal — three certificates issued, the MIDDLE one
// cancelled and replaced, and the register printed.
//
// Everything is asserted against what actually happened rather than what the
// page said: the serials come off FR-T02's counter, the cancelled row is
// read back off certificate_issue, the cross-reference is checked in BOTH
// directions, the append-only refusal is provoked with a real service-role
// UPDATE and DELETE, and the exported PDF's bytes are decoded and checked.
//
// Same posture as e2e/transfer-certificate-issuance.spec.ts, whose issuing
// machinery this builds on.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

/** A4 landscape in PDF points (1pt = 1/72in), rounded — the register is wide. */
const A4_LANDSCAPE_WIDTH_PT = 842;

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

/** The register export is handed over as a document, not as a stored link. */
function decodeDataUrlPdf(href: string): Buffer {
  const base64 = href.split(',')[1];
  if (!base64) throw new Error('export link carried no payload');
  return Buffer.from(base64, 'base64');
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@certreg-e2e.test`;
  const principalEmail = `principal-${runId}@certreg-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `certreg-e2e-${runId}`,
    p_legal_name: `Cert Register E2E School ${runId}`,
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

  const makeUser = async (email: string, role: 'owner' | 'principal', fullName: string) => {
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
  await makeUser(principalEmail, 'principal', 'Nusrat Jamil');

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

  // Students, enrolments and the template go through a SIGNED-IN client:
  // those RPCs read JWT role/campus claims a service-role call never
  // carries, and enrolment's fee-plan trigger looks the new row up by
  // app.auth_tenant_id().
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  // Four students for three certificates: the issuing form only renders
  // while at least one actively enrolled student is left, and the result
  // panel lives inside it.
  const cohort = [
    { name: 'Ali Raza', dob: '2011-03-04', gender: 'male' as const },
    { name: 'Zoya Sheikh', dob: '2012-07-21', gender: 'female' as const },
    { name: 'Hamza Iqbal', dob: '2012-01-09', gender: 'male' as const },
    { name: 'Ayesha Noor', dob: '2011-11-02', gender: 'female' as const },
  ];
  const students: Array<{ id: string; gr: string; name: string }> = [];
  for (const s of cohort) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
      p_gender: s.gender,
      p_father_name_en: 'Muhammad Raza',
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');
    const { error: enrolError } = await ownerClient.rpc('enrol_student', { p_section_id: section.id, p_student_id: studentId as string });
    if (enrolError) throw enrolError;
    const { data: row } = await admin.from('student').select('gr_number').eq('id', studentId as string).single();
    students.push({ id: studentId as string, gr: row!.gr_number as string, name: s.name });
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

  return { admin, principalEmail, tenantId: tenantId as string, campusId: campus!.id as string, students };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function issueTransferCertificate(page: import('@playwright/test').Page, gr: string, reason: string) {
  await page.goto('/certificates/issue');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('cert-issue-student-trigger').click();
  await page.getByTestId(`cert-issue-student-${gr}`).click();
  await page.getByTestId('cert-issue-template-trigger').click();
  await page.getByTestId('cert-issue-template-FBISE-en').click();
  await page.getByTestId('cert-issue-leaving-date').fill(new Date().toISOString().slice(0, 10));
  await page.getByTestId('cert-issue-conduct').fill('Good');
  await page.getByTestId('cert-issue-reason').fill(reason);
  await page.getByTestId('cert-issue-submit').click();
  await expect(page.getByTestId('cert-issue-result')).toBeVisible({ timeout: 90_000 });
}

test('a cancelled certificate stays in sequence with its replacement, and the register prints', async ({ page, browser }) => {
  test.setTimeout(300_000);
  const { admin, principalEmail, tenantId, campusId, students } = await seed();
  const year = new Date().getFullYear();
  const serial = (n: number) => `TC-${year}-${String(n).padStart(6, '0')}`;

  await signIn(page, principalEmail);

  // ── Three certificates, so the one that gets cancelled has neighbours ──
  await issueTransferCertificate(page, students[0]!.gr, 'Family relocation');
  await issueTransferCertificate(page, students[1]!.gr, 'Family relocation');
  await issueTransferCertificate(page, students[2]!.gr, 'Family relocation');

  await page.goto(`/certificates/register?type=transfer&year=${year}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Statutory certificate register' })).toBeVisible();
  await expect(page.getByTestId('register-continuity')).toContainText('a continuous run with no missing numbers');
  for (const n of [1, 2, 3]) {
    await expect(page.getByTestId(`register-status-${serial(n)}`)).toHaveText('ISSUED');
  }

  // ── AC2: cancel the MIDDLE entry, with a reason ───────────────────────
  await page.getByTestId(`register-cancel-${serial(2)}`).click();
  await page.getByTestId('register-cancel-reason').fill('wrong date of birth');
  await page.getByTestId('register-cancel-submit').click();
  await expect(page.getByTestId(`register-status-${serial(2)}`)).toHaveText('CANCELLED', { timeout: 30_000 });

  // The entry is still there, still numbered 2, and the counter was not
  // rewound — cancellation frees no number.
  const { data: cancelled } = await admin
    .from('certificate_issue')
    .select('id, serial_no, serial_seq, status, revoke_reason, revoked_by, revoked_at')
    .eq('student_id', students[1]!.id)
    .single();
  expect(cancelled!.serial_no).toBe(serial(2));
  expect(Number(cancelled!.serial_seq)).toBe(2);
  expect(cancelled!.status).toBe('cancelled');
  expect(cancelled!.revoke_reason).toBe('wrong date of birth');
  expect(cancelled!.revoked_by).not.toBeNull();
  expect(cancelled!.revoked_at).not.toBeNull();

  const { data: counter } = await admin
    .from('certificate_serial_counter')
    .select('current_value')
    .eq('campus_id', campusId)
    .eq('certificate_type', 'transfer')
    .single();
  expect(Number(counter!.current_value)).toBe(3);

  // ── AC2: the replacement is a NEW issuance with its own number ────────
  await issueTransferCertificate(page, students[1]!.gr, 'Reissued with the corrected date of birth');
  await expect(page.getByTestId('cert-issue-result')).toContainText(serial(4));

  await page.goto(`/certificates/register?type=transfer&year=${year}`);
  await page.waitForLoadState('networkidle');
  await page.getByTestId(`register-link-${serial(2)}`).click();
  await page.getByTestId('register-link-trigger').click();
  await page.getByTestId(`register-link-option-${serial(4)}`).click();
  await page.getByTestId('register-link-submit').click();
  await expect(page.getByTestId(`register-crossref-${serial(2)}`)).toContainText(`Replaced by ${serial(4)}`, {
    timeout: 30_000,
  });

  // ── AC2: in sequence, both ways round, nothing renumbered ─────────────
  const printedSerials = await page.locator('tbody tr td:nth-child(2)').allTextContents();
  expect(printedSerials).toEqual([serial(1), serial(2), serial(3), serial(4)]);
  await expect(page.getByTestId(`register-status-${serial(2)}`)).toHaveText('CANCELLED');
  await expect(page.getByTestId(`register-status-${serial(1)}`)).toHaveText('ISSUED');
  await expect(page.getByTestId(`register-status-${serial(3)}`)).toHaveText('ISSUED');
  await expect(page.getByTestId(`register-row-${serial(2)}`)).toContainText('wrong date of birth');
  await expect(page.getByTestId(`register-row-${serial(2)}`)).toContainText('Nusrat Jamil');
  await expect(page.getByTestId(`register-crossref-${serial(4)}`)).toContainText(`Replaces ${serial(2)}`);
  await expect(page.getByTestId('register-continuity')).toContainText('a continuous run with no missing numbers');

  // ── AC1 + AC4: the register really is append-only, from a service-role
  // key that bypasses RLS entirely ──────────────────────────────────────
  const { error: updateError } = await admin
    .from('certificate_issue')
    .update({ serial_no: 'TC-FORGED-000001' })
    .eq('id', cancelled!.id);
  expect(updateError?.message).toContain('certificate register is append-only');

  const { error: deleteError } = await admin.from('certificate_issue').delete().eq('id', cancelled!.id);
  expect(deleteError?.message).toContain('certificate register is append-only');

  const { data: stillThere } = await admin
    .from('certificate_issue')
    .select('serial_no, status')
    .eq('id', cancelled!.id)
    .single();
  expect(stillThere!.serial_no).toBe(serial(2));
  expect(stillThere!.status).toBe('cancelled');

  // ── AC3: the printed register, as real bytes ──────────────────────────
  await page.getByTestId('register-export-button').click();
  await expect(page.getByTestId('register-export-result')).toBeVisible({ timeout: 120_000 });
  await expect(page.getByTestId('register-export-result')).toContainText('4 entries printed');

  const href = await page.getByTestId('register-export-link').getAttribute('href');
  expect(href).toMatch(/^data:application\/pdf;base64,/);
  const pdf = decodeDataUrlPdf(href!);
  expect(pdf.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(pdf.length).toBeGreaterThan(1000);
  expect(pdfFirstMediaBox(pdf).width).toBe(A4_LANDSCAPE_WIDTH_PT);
  const download = await page.getByTestId('register-export-link').getAttribute('download');
  expect(download).toBe(`certificate-register-transfer-${year}.pdf`);

  // ── An Admissions Officer may issue, but the register page is not theirs
  const clerkEmail = `clerk-${randomUUID().slice(0, 8)}@certreg-e2e.test`;
  const { data: clerk } = await admin.auth.admin.createUser({
    email: clerkEmail,
    password: PASSWORD,
    email_confirm: true,
  });
  await admin
    .from('app_user')
    .insert({ user_id: clerk.user!.id, tenant_id: tenantId, app_role: 'admissions_officer', full_name: 'Farhat Jabeen' });
  await admin.from('user_campus').insert({ user_id: clerk.user!.id, tenant_id: tenantId, campus_id: campusId });

  const clerkContext = await browser.newContext();
  const clerkPage = await clerkContext.newPage();
  await signIn(clerkPage, clerkEmail);
  await clerkPage.goto(`/certificates/register?type=transfer&year=${year}`);
  await clerkPage.waitForLoadState('networkidle');
  await expect(clerkPage.getByTestId('cert-register-forbidden')).toBeVisible();
  await clerkContext.close();
});
