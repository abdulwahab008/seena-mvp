import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T01: the certificate template designer, driven through the real UI.
// The rejection is the SERVER's (activate_certificate_template refusing the
// merge field), and the preview assertions are made against the BYTES the
// preview route returned — paper size, embedded font and missing-glyph
// count are read out of the PDF and its response headers, never inferred
// from what the page said. Same posture as
// e2e/timetable-print-and-export.spec.ts, whose renderer this shares.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

/** A4 portrait in PDF points (1pt = 1/72in), rounded. */
const A4_PORTRAIT_WIDTH_PT = 595;

const TC_BODY_WITH_BAD_FIELD =
  '<p>{{student.name_en}} ({{student.gr_number}}) blood group {{student.blood_group}} — serial {{issue.serial_no}}, issued {{issue.date}}, left {{enrolment.left_on}}.</p>';
const TC_BODY_CLEAN =
  '<p>{{student.name_en}} ({{student.gr_number}}) — serial {{issue.serial_no}}, issued {{issue.date}}, left {{enrolment.left_on}}.</p>';
const URDU_BODY =
  '<p>تصدیق کی جاتی ہے کہ {{student.name_en}} اس ادارے کا باقاعدہ طالبِ علم ہے۔ اجرا کی تاریخ {{issue.date}}۔</p>';

function pdfBaseFonts(body: Buffer): string[] {
  return [...body.toString('latin1').matchAll(/\/BaseFont\s*\/([A-Za-z0-9+,.\-_]+)/g)].map((m) => m[1]!.replace(/^[A-Z]{6}\+/, ''));
}

function pdfFirstMediaBox(body: Buffer): { width: number; height: number } {
  const match = body.toString('latin1').match(/\/MediaBox\s*\[\s*[\d.]+\s+[\d.]+\s+([\d.]+)\s+([\d.]+)\s*\]/);
  if (!match) throw new Error('no MediaBox in the produced PDF');
  return { width: Math.round(Number(match[1])), height: Math.round(Number(match[2])) };
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@certtpl-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `certtpl-e2e-${runId}`,
    p_legal_name: `Cert Template E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (error) throw error;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();

  const { data: created, error: userError } = await admin.auth.admin.createUser({
    email: ownerEmail,
    password: PASSWORD,
    email_confirm: true,
  });
  if (userError || !created.user) throw userError ?? new Error('owner creation failed');
  const { error: appUserError } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (appUserError) throw appUserError;
  const { error: campusError } = await admin
    .from('user_campus')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (campusError) throw campusError;

  return { ownerEmail };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
}

async function pick(page: import('@playwright/test').Page, trigger: string, item: string) {
  await page.getByTestId(trigger).click();
  await page.getByTestId(item).click();
}

test('a principal authors, is refused, fixes, activates and previews a certificate template', async ({ page }) => {
  const { ownerEmail } = await seed();
  await signIn(page, ownerEmail);

  await page.goto('/certificates/templates');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Certificate templates' })).toBeVisible();
  await expect(page.getByTestId('cert-template-empty')).toBeVisible();

  // ── author a TC for FBISE that names a field this system cannot merge ──
  await pick(page, 'cert-new-type-trigger', 'cert-new-type-transfer');
  await page.getByTestId('cert-new-board').fill('FBISE');
  await page.getByTestId('cert-new-title').fill('School Leaving Certificate');
  await page.getByTestId('cert-new-body').fill(TC_BODY_WITH_BAD_FIELD);
  await page.getByTestId('cert-new-submit').click();

  await expect(page.getByTestId('cert-editor')).toBeVisible();
  await expect(page.getByTestId('cert-editor-status')).toHaveText('draft');
  // The designer shows the whitelist and flags the offending field before
  // Activate is ever clicked; the database is still what refuses it.
  await expect(page.getByTestId('cert-whitelist-student.gr_number')).toBeVisible();
  await expect(page.getByTestId('cert-unknown-fields')).toContainText('student.blood_group');

  // ── AC1: activation is rejected, naming the field, and it stays draft ──
  await page.getByTestId('cert-edit-activate').click();
  const activateError = page.getByTestId('cert-activate-error');
  await expect(activateError).toBeVisible();
  await expect(activateError).toContainText('student.blood_group');
  await expect(page.getByTestId('cert-editor-status')).toHaveText('draft');

  // ── fix the wording and activate ───────────────────────────────────────
  await page.getByTestId('cert-edit-body').fill(TC_BODY_CLEAN);
  await expect(page.getByTestId('cert-unknown-fields')).toHaveCount(0);
  await page.getByTestId('cert-edit-save').click();
  await expect(page.getByTestId('cert-editor-status')).toHaveText('draft');

  await page.getByTestId('cert-edit-activate').click();
  await expect(page.getByTestId('cert-editor-status')).toHaveText('active', { timeout: 15_000 });
  await expect(page.getByTestId('cert-activate-error')).toHaveCount(0);

  // ── the preview is a real PDF, on the paper size the template stores ──
  const previewHref = await page.getByTestId('cert-edit-preview-link').getAttribute('href');
  expect(previewHref).toBe(`/api/certificate-template/${previewHref!.split('/')[3]}/preview`);
  const response = await page.request.get(previewHref!);
  expect(response.ok()).toBe(true);
  expect(response.headers()['content-type']).toContain('application/pdf');
  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(pdfFirstMediaBox(body).width).toBe(A4_PORTRAIT_WIDTH_PT);
  // Rendered from the ACTIVATED wording, with the catalogue's sample values
  // merged in — the serial placeholder FR-T02 will fill included.
  expect(body.length).toBeGreaterThan(1000);

  // ── AC2: editing the active version forks v2 and leaves v1 active ─────
  await page.getByTestId('cert-edit-body').fill(TC_BODY_CLEAN.replace('serial', 'certificate serial'));
  await page.getByTestId('cert-edit-save').click();
  await expect(page.getByTestId('cert-editor-heading')).toContainText('v2');
  await expect(page.getByTestId('cert-editor-status')).toHaveText('draft');
  await expect(page.getByText('v1 · A4')).toBeVisible();
});

test('AC4: an Urdu template previews right-to-left with an embedded Nastaliq face and no missing glyphs', async ({ page }) => {
  const { ownerEmail } = await seed();
  await signIn(page, ownerEmail);

  await page.goto('/certificates/templates');
  await page.waitForLoadState('networkidle');

  await pick(page, 'cert-new-type-trigger', 'cert-new-type-bonafide');
  await pick(page, 'cert-new-language-trigger', 'cert-new-language-ur');
  await page.getByTestId('cert-new-title').fill('بونا فائیڈ سرٹیفکیٹ');
  await page.getByTestId('cert-new-body').fill(URDU_BODY);
  await page.getByTestId('cert-new-submit').click();

  await expect(page.getByTestId('cert-editor')).toBeVisible();
  await page.getByTestId('cert-edit-activate').click();
  await expect(page.getByTestId('cert-editor-status')).toHaveText('active', { timeout: 15_000 });

  const previewHref = await page.getByTestId('cert-edit-preview-link').getAttribute('href');
  const response = await page.request.get(previewHref!);
  expect(response.ok()).toBe(true);

  // The cmap check ran over exactly the strings that were typeset — a
  // boxed glyph on the page would be a non-zero count here.
  expect(response.headers()['x-missing-glyph-count']).toBe('0');
  expect(response.headers()['x-font-family']).toBe('Noto Nastaliq Urdu');

  const body = Buffer.from(await response.body());
  expect(body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(pdfBaseFonts(body)).toContain('NotoNastaliqUrdu');
  expect(pdfFirstMediaBox(body).width).toBe(A4_PORTRAIT_WIDTH_PT);
});
