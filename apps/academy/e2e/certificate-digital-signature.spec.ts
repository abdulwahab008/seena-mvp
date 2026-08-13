import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { createHash, randomUUID } from 'node:crypto';
import { makeSolidPng } from './fixtures/png';

// FR-T09: the signature, the stamp and the digest, end to end and against
// real bytes. Every assertion is made on what actually happened rather than
// on what the page said: the PDF is fetched through the download route that
// verifies it, the composited images are counted out of the file's own
// object dictionary, the digest is recomputed here and compared to the one
// the register stored, and the tamper is a genuine overwrite of the stored
// object with a service-role key before the download is retried.
//
// Same posture as e2e/transfer-certificate-issuance.spec.ts (FR-T03), whose
// issuing flow this extends.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const TC_BODY =
  '<p>This is to certify that {{student.name_en}}, GR No. {{student.gr_number}}, born {{student.dob}} ' +
  '({{student.dob_words}}), of {{enrolment.class_name}} {{enrolment.section_name}}, left this institution on ' +
  '{{enrolment.left_on}}. Conduct: {{transfer.conduct}}. Reason: {{transfer.reason}}. ' +
  'Serial No. {{issue.serial_no}}, issued {{issue.date}}. ' +
  'Signed: {{signatory.name}}, {{signatory.designation}}.</p>';

/** Image XObjects embedded in the file — the composited signature and stamp. */
function pdfImageCount(body: Buffer): number {
  return body.toString('latin1').match(/\/Subtype\s*\/Image/g)?.length ?? 0;
}

function sha256(bytes: Buffer): string {
  return createHash('sha256').update(bytes).digest('hex');
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@certsign-e2e.test`;
  const clerkEmail = `clerk-${runId}@certsign-e2e.test`;
  const principalEmail = `principal-${runId}@certsign-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `certsign-e2e-${runId}`,
    p_legal_name: `Cert Signing E2E School ${runId}`,
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

  const makeUser = async (email: string, role: 'owner' | 'admissions_officer' | 'principal', fullName: string) => {
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
  await makeUser(clerkEmail, 'admissions_officer', 'Farhat Clerk');
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
  // carries. Same convention as e2e/transfer-certificate-issuance.spec.ts.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  // Two spare students so the issuing form stays on screen after the first
  // certificate takes its own student off the roster — the same reason
  // e2e/transfer-certificate-issuance.spec.ts seeds a cohort.
  const cohort = [
    { name: 'Ali Raza', dob: '2011-03-04', gender: 'male' as const },
    { name: 'Zoya Sheikh', dob: '2012-07-21', gender: 'female' as const },
    { name: 'Hamza Iqbal', dob: '2012-01-09', gender: 'male' as const },
  ];
  const studentIds: string[] = [];
  for (const s of cohort) {
    const { data: newStudentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: s.name,
      p_dob: s.dob,
      p_gender: s.gender,
      p_father_name_en: 'Muhammad Raza',
    });
    if (studentError || !newStudentId) throw studentError ?? new Error('student creation failed');
    studentIds.push(newStudentId as string);
    const { error: enrolError } = await ownerClient.rpc('enrol_student', { p_section_id: section.id, p_student_id: newStudentId as string });
    if (enrolError) throw enrolError;
  }
  const studentId = studentIds[0]!;

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

  const { data: student } = await admin.from('student').select('id, gr_number').eq('id', studentId).single();

  return {
    admin,
    ownerEmail,
    clerkEmail,
    principalEmail,
    tenantId: tenantId as string,
    campusId: campus!.id as string,
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

// The whole issuing sequence — two uploads, a Chromium render, an upload,
// a read-back and a hash — is well past Playwright's 30s default.
test.setTimeout(180_000);

test('a signed certificate carries the composited signature, a stored digest, and 409s once its bytes are altered', async ({ page }) => {
  const { admin, ownerEmail, clerkEmail, principalEmail, tenantId, campusId, studentGr } = await seed();
  const today = new Date().toISOString().slice(0, 10);

  // ── The Owner sets who signs ──────────────────────────────────────────
  await signIn(page, ownerEmail);
  await page.goto('/certificates/signing');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('signing-identities-empty')).toBeVisible();

  // AC1: a signature that cannot print 45mm at 300 DPI is refused rather
  // than upscaled — 300px is fine for FR-A18's branding floor and not for
  // this one.
  await page.getByTestId('signing-holder-name').fill('Farhat Jabeen');
  await page.getByTestId('signing-designation').fill('Principal');
  await page.getByTestId('signing-signature-input').setInputFiles({
    name: 'signature-small.png',
    mimeType: 'image/png',
    buffer: makeSolidPng(300, 100),
  });
  await page.getByTestId('signing-submit').click();
  await expect(page.getByText('at least 532px')).toBeVisible({ timeout: 30_000 });

  // React clears an uncontrolled form once its action settles, so the new
  // files have to go in after that has happened — otherwise they are the
  // ones being wiped.
  await expect(page.getByTestId('signing-signature-input')).toHaveValue('');

  await page.getByTestId('signing-holder-name').fill('Farhat Jabeen');
  await page.getByTestId('signing-designation').fill('Principal');
  await page.getByTestId('signing-signature-input').setInputFiles({
    name: 'signature.png',
    mimeType: 'image/png',
    buffer: makeSolidPng(900, 300),
  });
  await page.getByTestId('signing-stamp-input').setInputFiles({
    name: 'stamp.png',
    mimeType: 'image/png',
    buffer: makeSolidPng(800, 800),
  });
  await page.getByTestId('signing-submit').click();
  await expect(page.getByText('Farhat Jabeen now signs certificates at this campus.')).toBeVisible({ timeout: 30_000 });
  await expect(page.locator('[data-testid^="signing-identity-row-"]')).toHaveCount(1);

  const { data: identity } = await admin
    .from('signing_identity')
    .select('id, holder_name, designation, valid_to, signature_asset_id, stamp_asset_id')
    .eq('tenant_id', tenantId)
    .single();
  expect(identity!.holder_name).toBe('Farhat Jabeen');
  expect(identity!.valid_to).toBeNull();
  expect(identity!.stamp_asset_id).not.toBeNull();

  // ── AC4: a Principal cannot supply a signature ────────────────────────
  // The RPC gate first, then the storage policy the AC actually names: the
  // Owner reserves a path, and the Principal is refused the bytes.
  const principalClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: principalSignIn } = await principalClient.auth.signInWithPassword({ email: principalEmail, password: PASSWORD });
  expect(principalSignIn).toBeNull();

  const { error: principalReserve } = await principalClient.rpc('create_branding_asset', {
    p_asset_type: 'signature',
    p_width_px: 900,
    p_height_px: 300,
    p_bytes: 20_000,
    p_mime_type: 'image/png',
    p_file_ext: 'png',
    p_campus_id: campusId,
  });
  expect(principalReserve?.message).toContain('FORBIDDEN');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  const { data: reservation } = await ownerClient.rpc('create_branding_asset', {
    p_asset_type: 'signature',
    p_width_px: 900,
    p_height_px: 300,
    p_bytes: 20_000,
    p_mime_type: 'image/png',
    p_file_ext: 'png',
    p_campus_id: campusId,
  });
  const reservedPath = (reservation as unknown as { storage_path: string }).storage_path;

  const principalUpload = await principalClient.storage
    .from('branding')
    .upload(reservedPath, makeSolidPng(900, 300), { contentType: 'image/png', upsert: false });
  expect(principalUpload.error).not.toBeNull();
  // …and the object really is not there.
  const { data: strayObject } = await admin.storage.from('branding').list(reservedPath.split('/').slice(0, -1).join('/'));
  expect((strayObject ?? []).some((o) => reservedPath.endsWith(o.name))).toBe(false);

  // ── The clerk issues, and the document is sealed ──────────────────────
  await signIn(page, clerkEmail);
  await page.goto('/certificates/issue');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('cert-issue-student-trigger').click();
  await page.getByTestId(`cert-issue-student-${studentGr}`).click();
  await page.getByTestId('cert-issue-template-trigger').click();
  await page.getByTestId('cert-issue-template-FBISE-en').click();
  await page.getByTestId('cert-issue-leaving-date').fill(today);
  await page.getByTestId('cert-issue-conduct').fill('Good');
  await page.getByTestId('cert-issue-reason').fill('Family relocation');
  await page.getByTestId('cert-issue-submit').click();

  const result = page.getByTestId('cert-issue-result');
  await expect(result).toBeVisible({ timeout: 60_000 });

  const { data: issueRow } = await admin
    .from('certificate_issue')
    .select('id, serial_no, status, pdf_path, pdf_sha256, signing_identity_id, payload_snapshot')
    .eq('tenant_id', tenantId)
    .single();
  expect(issueRow!.status).toBe('issued');

  // AC3: the register records who signed it, and the snapshot froze the
  // exact image and anchor the document was printed with.
  expect(issueRow!.signing_identity_id).toBe(identity!.id);
  const snapshot = issueRow!.payload_snapshot as {
    values: Record<string, string>;
    seal: { signature_anchor_x_mm: number; signature_anchor_y_mm: number; stamp_opacity: number; signature_storage_path: string };
  };
  expect(snapshot.values['signatory.name']).toBe('Farhat Jabeen');
  expect(snapshot.values['signatory.designation']).toBe('Principal');
  expect(snapshot.seal.signature_anchor_x_mm).toBe(140);
  expect(snapshot.seal.signature_anchor_y_mm).toBe(235);
  expect(snapshot.seal.stamp_opacity).toBe(0.6);

  // ── AC1/AC2: the real bytes, through the verifying download route ─────
  const href = await page.getByTestId('cert-issue-download-link').getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);
  expect(href).toContain(`/api/certificates/${issueRow!.id}/download`);

  const response = await page.request.get(href!);
  expect(response.status()).toBe(200);
  expect(response.headers()['x-pdf-digest-status']).toBe('match');
  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');

  // AC1: the signature and the stamp are really composited into the file —
  // two image objects in a document whose template has no letterhead and no
  // logo.
  expect(pdfImageCount(body)).toBeGreaterThanOrEqual(2);

  // The digest on the register row is the digest of the bytes in the bucket.
  const stored = await admin.storage.from('certificates').download(issueRow!.pdf_path);
  expect(stored.error).toBeNull();
  const storedBytes = Buffer.from(await stored.data!.arrayBuffer());
  expect(issueRow!.pdf_sha256).toMatch(/^[0-9a-f]{64}$/);
  expect(issueRow!.pdf_sha256).toBe(sha256(storedBytes));
  expect(sha256(body)).toBe(issueRow!.pdf_sha256);

  // ── AC2: the forgery ─────────────────────────────────────────────────
  // A service-role key overwriting the object is the strongest attacker the
  // storage policies leave standing (they have no UPDATE policy at all, so
  // no application role can do this).
  const forged = Buffer.concat([storedBytes.subarray(0, storedBytes.length - 40), Buffer.from('%FORGED'.padEnd(40, ' '), 'latin1')]);
  const { error: overwriteError } = await admin.storage
    .from('certificates')
    .upload(issueRow!.pdf_path, forged, { contentType: 'application/pdf', upsert: true });
  expect(overwriteError).toBeNull();
  expect(sha256(forged)).not.toBe(issueRow!.pdf_sha256);

  const tamperedResponse = await page.request.get(href!);
  expect(tamperedResponse.status()).toBe(409);
  expect(tamperedResponse.headers()['x-pdf-digest-status']).toBe('mismatch');
  const tamperedBody = (await tamperedResponse.json()) as { error: string; expectedSha256: string; observedSha256: string };
  expect(tamperedBody.error).toContain('altered');
  expect(tamperedBody.expectedSha256).toBe(issueRow!.pdf_sha256);
  expect(tamperedBody.observedSha256).toBe(sha256(forged));

  // …and the attempt is on the record.
  const { data: alerts } = await admin
    .from('security_event')
    .select('event_type, severity, subject_id, detail')
    .eq('tenant_id', tenantId);
  expect(alerts).toHaveLength(1);
  expect(alerts![0]!.event_type).toBe('certificate_digest_mismatch');
  expect(alerts![0]!.severity).toBe('alert');
  expect(alerts![0]!.subject_id).toBe(issueRow!.id);
  const detail = alerts![0]!.detail as { expected_sha256: string; observed_sha256: string };
  expect(detail.expected_sha256).toBe(issueRow!.pdf_sha256);
  expect(detail.observed_sha256).toBe(sha256(forged));

  // The register row itself is untouched by any of it — the digest is
  // write-once, so the forger cannot make the stored bytes look authentic.
  const { data: afterRow } = await admin.from('certificate_issue').select('pdf_sha256, status').eq('id', issueRow!.id).single();
  expect(afterRow!.pdf_sha256).toBe(issueRow!.pdf_sha256);
  expect(afterRow!.status).toBe('issued');

  // ── AC4, in the UI ───────────────────────────────────────────────────
  await signIn(page, principalEmail);
  await page.goto('/certificates/signing');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('signing-forbidden')).toBeVisible();
});
