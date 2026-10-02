import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

async function seedTenant() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@consent-e2e.test`;
  const parentEmail = `parent-${runId}@consent-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `consent-e2e-${runId}`,
    p_legal_name: `Consent E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await db.auth.admin.createUser({
    email: ownerEmail,
    password: PASSWORD,
    email_confirm: true,
  });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await db
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // The guardian's own portal login. FR-C11 activates these over OTP; that
  // flow has its own spec, so this one provisions the same end state
  // directly and spends its time on consent instead.
  const { data: parentUser, error: e4 } = await db.auth.admin.createUser({
    email: parentEmail,
    password: PASSWORD,
    email_confirm: true,
  });
  if (e4 || !parentUser.user) throw e4 ?? new Error('parent creation failed');
  const { error: e5 } = await db
    .from('app_user')
    .insert({ user_id: parentUser.user.id, tenant_id: tenantId as string, app_role: 'parent', full_name: 'E2E Parent' });
  if (e5) throw e5;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await db
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  const { error: e6 } = await db.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 30,
  });
  if (e6) throw e6;

  return { tenantId: tenantId as string, ownerEmail, parentEmail, parentUserId: parentUser.user.id };
}

// Staff land on the dashboard; a guardian has no app_user row and is sent to
// their own portal instead, so the caller says which of the two it expects.
async function signIn(
  page: import('@playwright/test').Page,
  email: string,
  lands: 'staff' | 'portal' = 'staff',
) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(lands === 'portal' ? /\/portal\// : /\/dashboard$/);
}

// Admit + enrol through the real UI: enrolment's AFTER INSERT trigger needs
// a JWT, the same gotcha every spec in this suite works around by never
// inserting enrolment rows directly.
async function admitAndEnrol(page: import('@playwright/test').Page, name: string) {
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill(name);
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText(`${name} admitted.`)).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();
  return studentId;
}

async function selectOption(page: import('@playwright/test').Page, trigger: string, option: string) {
  await page.getByTestId(trigger).click();
  await page.getByTestId(option).click();
}

test('consent is captured on paper, contradicted by a second guardian, enforced by the gallery export, and withdrawn from the portal', async ({
  page,
}) => {
  const { tenantId, ownerEmail, parentEmail, parentUserId } = await seedTenant();
  const db = admin();

  await signIn(page, ownerEmail);
  const alphaId = await admitAndEnrol(page, 'Consent Alpha');
  const betaId = await admitAndEnrol(page, 'Consent Beta');

  // A photograph on file is the precondition for being in a gallery at all;
  // student.photo_path has no upload UI yet (see the migration header).
  const { error: ePhoto } = await db
    .from('student')
    .update({ photo_path: `${tenantId}/photos/placeholder.jpg` })
    .in('id', [alphaId, betaId]);
  if (ePhoto) throw ePhoto;

  // Alpha has two guardians who will disagree; Beta has one, who also holds
  // the portal login.
  const { data: guardians, error: eg } = await db
    .from('guardian')
    .insert([
      { tenant_id: tenantId, name_en: 'Alpha Father', phone_e164: '+923009990001' },
      { tenant_id: tenantId, name_en: 'Alpha Mother', phone_e164: '+923009990002' },
      { tenant_id: tenantId, name_en: 'Beta Father', phone_e164: '+923009990003', auth_user_id: parentUserId },
    ])
    .select('id, name_en');
  if (eg) throw eg;
  const gid = (name: string) => guardians!.find((g) => g.name_en === name)!.id;

  const { error: el } = await db.from('student_guardian').insert([
    { tenant_id: tenantId, student_id: alphaId, guardian_id: gid('Alpha Father'), relationship: 'father', is_primary: true, receives_billing: true },
    { tenant_id: tenantId, student_id: alphaId, guardian_id: gid('Alpha Mother'), relationship: 'mother', is_primary: false, receives_billing: false },
    { tenant_id: tenantId, student_id: betaId, guardian_id: gid('Beta Father'), relationship: 'father', is_primary: true, receives_billing: true },
  ]);
  if (el) throw el;

  await page.goto('/consent');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('consent-no-conflicts')).toBeVisible();

  // ── AC5: the paper admission form, keyed in with its scan ──────────────
  await selectOption(page, 'consent-student-trigger', 'consent-student-option-Consent Beta');
  await expect(page.getByTestId('consent-effective-student_photo_marketing')).toHaveText('No');

  await selectOption(page, 'consent-purpose-trigger', 'consent-purpose-option-student_photo_marketing');
  await selectOption(page, 'consent-guardian-trigger', 'consent-guardian-option-Beta Father');
  await selectOption(page, 'consent-decision-trigger', 'consent-decision-option-granted');
  await selectOption(page, 'consent-channel-trigger', 'consent-channel-option-paper');
  await page.getByTestId('consent-evidence-input').setInputFiles({
    name: 'admission-form.pdf',
    mimeType: 'application/pdf',
    buffer: Buffer.from('%PDF-1.4 signed consent'),
  });
  await page.getByTestId('consent-record-button').click();
  await expect(page.getByText('Recorded — consent is in force.')).toBeVisible();
  await expect(page.getByTestId('consent-effective-student_photo_marketing')).toHaveText('Yes');
  await expect(page.getByTestId('consent-decision-list')).toContainText('Paper form');

  // ── AC4: the second guardian says no, and the no wins ─────────────────
  await selectOption(page, 'consent-student-trigger', 'consent-student-option-Consent Alpha');
  await selectOption(page, 'consent-guardian-trigger', 'consent-guardian-option-Alpha Father');
  await selectOption(page, 'consent-decision-trigger', 'consent-decision-option-granted');
  await selectOption(page, 'consent-channel-trigger', 'consent-channel-option-counter');
  await page.getByTestId('consent-record-button').click();
  await expect(page.getByText('Recorded — consent is in force.')).toBeVisible();
  await expect(page.getByTestId('consent-effective-student_photo_marketing')).toHaveText('Yes');

  await selectOption(page, 'consent-guardian-trigger', 'consent-guardian-option-Alpha Mother');
  await selectOption(page, 'consent-decision-trigger', 'consent-decision-option-denied');
  await page.getByTestId('consent-record-button').click();
  await expect(page.getByText('Recorded — this purpose is now blocked.')).toBeVisible();
  await expect(page.getByTestId('consent-effective-student_photo_marketing')).toHaveText('No');
  await expect(page.getByTestId('consent-flag-conflict-student_photo_marketing')).toBeVisible();

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('consent-conflict-Consent Alpha')).toContainText('resolves to DENIED');

  // ── AC1: the gallery excludes the denied student, and says so ─────────
  await page.getByTestId('gallery-build-button').click();
  await expect(page.getByTestId('gallery-result')).toHaveText(
    '1 included · 1 excluded (consent denied) · 0 excluded (no consent on file) · 0 excluded (no photograph)',
  );

  // AC1's audit row: the exclusion is in audit_log, with its reason.
  const { data: auditRows, error: eAudit } = await db
    .from('audit_log')
    .select('after')
    .eq('tenant_id', tenantId)
    .eq('table_name', 'marketing_gallery_export_exclusion')
    .eq('action', 'insert');
  if (eAudit) throw eAudit;
  const reasons = (auditRows ?? []).map((r) => (r.after as { reason: string; student_id: string }));
  expect(reasons.filter((r) => r.reason === 'consent_denied' && r.student_id === alphaId)).toHaveLength(1);

  // ── AC3: the wording is revised; old consents stay valid but get flagged
  const { error: eVersion } = await db.from('consent_text_version').insert({
    tenant_id: tenantId,
    purpose_code: 'student_photo_marketing',
    version: 2,
    body_en: 'Revised photograph consent wording.',
  });
  if (eVersion) throw eVersion;

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('consent-reconsent-Consent Beta')).toContainText('still valid');
  await selectOption(page, 'consent-student-trigger', 'consent-student-option-Consent Beta');
  await expect(page.getByTestId('consent-effective-student_photo_marketing')).toHaveText('Yes');
  await expect(page.getByTestId('consent-flag-reconsent-student_photo_marketing')).toContainText('Re-consent required (v2)');

  // The version bump on its own changes nothing about who is in the gallery.
  await page.getByTestId('gallery-build-button').click();
  await expect(page.getByTestId('gallery-result')).toHaveText(
    '1 included · 1 excluded (consent denied) · 0 excluded (no consent on file) · 0 excluded (no photograph)',
  );

  // ── The parent withdraws from the portal, and the gallery follows ─────
  await page.context().clearCookies();
  await signIn(page, parentEmail, 'portal');
  await page.goto('/portal/consent');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('portal-consent-status-student_photo_marketing')).toContainText('granted');
  await page.getByTestId('portal-consent-withdraw-student_photo_marketing').click();
  await expect(page.getByText('Your choice has been recorded.')).toBeVisible();
  await expect(page.getByTestId('portal-consent-status-student_photo_marketing')).toContainText('withdrawn');

  await page.context().clearCookies();
  await signIn(page, ownerEmail);
  await page.goto('/consent');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('gallery-build-button').click();
  await expect(page.getByTestId('gallery-result')).toHaveText(
    '0 included · 2 excluded (consent denied) · 0 excluded (no consent on file) · 0 excluded (no photograph)',
  );
});
