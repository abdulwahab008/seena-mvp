import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-F15: timetable print and export, exercised end to end through the real
// UI. Every assertion below is made against the BYTES that came back from
// the signed URL — page count, paper size and the embedded font are read
// out of the PDF itself, not inferred from what the app said it did.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

/** A3 landscape / A4 portrait in PDF points (1pt = 1/72in), rounded. */
const A4_PORTRAIT_WIDTH_PT = 595;
const A3_LANDSCAPE_WIDTH_PT = 1191;

function pdfPageCount(body: Buffer): number {
  return (body.toString('latin1').match(/\/Type\s*\/Page(?![a-zA-Z])/g) ?? []).length;
}

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
  const ownerEmail = `owner-${runId}@ttexport-e2e.test`;
  const ayeshaEmail = `ayesha-${runId}@ttexport-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `ttexport-e2e-${runId}`,
    p_legal_name: `TT Export E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const makeUser = async (email: string, role: 'owner' | 'subject_teacher', fullName: string) => {
    const { data: created, error } = await admin.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (error || !created.user) throw error ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await admin
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: role, full_name: fullName });
    if (appUserError) throw appUserError;
    const { error: campusError } = await admin
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
    if (campusError) throw campusError;
    return created.user.id;
  };

  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  const ayeshaId = await makeUser(ayeshaEmail, 'subject_teacher', 'Ms Ayesha');
  const bilalEmail = `bilal-${runId}@ttexport-e2e.test`;
  const bilalId = await makeUser(bilalEmail, 'subject_teacher', 'Mr Bilal');

  const sectionIds: string[] = [];
  for (const name of ['A', 'B', 'C']) {
    const { data: section, error } = await admin
      .from('class_section')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name,
        // AC4: an Urdu-medium section, so the Urdu subject name is the
        // leading line on that sheet rather than a secondary gloss.
        medium: name === 'C' ? 'URDU' : 'ENGLISH',
        capacity: 30,
      })
      .select('id')
      .single();
    if (error || !section) throw error ?? new Error('section creation failed');
    sectionIds.push(section.id);
  }

  const subjectIds: string[] = [];
  for (const [code, en, ur] of [
    ['PHY', 'Physics', 'فزکس'],
    ['ISL', 'Islamiat', 'اسلامیات'],
  ]) {
    const { data: subject, error } = await admin
      .from('subject')
      .insert({ tenant_id: tenantId as string, code, name_en: en, name_ur: ur })
      .select('id')
      .single();
    if (error || !subject) throw error ?? new Error('subject creation failed');
    subjectIds.push(subject.id);
  }

  const { data: version, error: versionError } = await admin
    .from('timetable_version')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      shift: 'MORNING',
      name: 'Term 1',
      status: 'PUBLISHED',
      version_no: 1,
      effective_from: '2026-08-01',
    })
    .select('id')
    .single();
  if (versionError || !version) throw versionError ?? new Error('version creation failed');

  const slots = [
    { section_id: sectionIds[0]!, weekday: 1, period_no: 1, subject_id: subjectIds[0]!, staff_id: ayeshaId },
    { section_id: sectionIds[1]!, weekday: 2, period_no: 2, subject_id: subjectIds[1]!, staff_id: bilalId },
    { section_id: sectionIds[2]!, weekday: 3, period_no: 1, subject_id: subjectIds[1]!, staff_id: ayeshaId },
  ];
  const { error: slotError } = await admin.from('timetable_slot').insert(
    slots.map((s) => ({ tenant_id: tenantId as string, campus_id: campus!.id, timetable_version_id: version.id, ...s })),
  );
  if (slotError) throw slotError;

  return { ownerEmail, ayeshaEmail, sectionCount: sectionIds.length };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
}

// The result panel stays on screen between runs, so a second export has to
// be recognised by its link CHANGING — reading the href as soon as the
// panel is visible silently re-downloads the previous layout's PDF.
async function generate(page: import('@playwright/test').Page, layout: 'section' | 'teacher' | 'master', previousHref: string | null) {
  await page.getByTestId('timetable-export-layout-trigger').click();
  await page.getByTestId(`timetable-export-layout-${layout}`).click();
  await page.getByTestId('timetable-export-run-button').click();

  const link = page.getByTestId('timetable-export-download-link');
  await expect(link).toBeVisible({ timeout: 60_000 });
  await expect.poll(() => link.getAttribute('href'), { timeout: 60_000 }).not.toBe(previousHref);

  const href = await link.getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);
  const response = await page.request.get(href!);
  expect(response.ok()).toBe(true);
  return { result: page.getByTestId('timetable-export-latest-result'), href: href!, body: Buffer.from(await response.body()) };
}

test('a principal exports section, teacher and master-grid timetables as real PDFs', async ({ page }) => {
  const { ownerEmail, sectionCount } = await seed();
  await signIn(page, ownerEmail);

  await page.goto('/academic-setup/timetable-export');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Timetable print & export' })).toBeVisible();

  // ── AC1: one page per section, A4 portrait, stored and downloadable ──
  const sectionExport = await generate(page, 'section', null);
  expect(sectionExport.body.subarray(0, 5).toString('latin1')).toBe('%PDF-');
  expect(pdfPageCount(sectionExport.body)).toBe(sectionCount);
  expect(pdfFirstMediaBox(sectionExport.body).width).toBe(A4_PORTRAIT_WIDTH_PT);
  await expect(sectionExport.result).toContainText(`${sectionCount} pages`);

  // ── AC4: the Nastaliq face is embedded, with zero missing glyphs ─────
  expect(pdfBaseFonts(sectionExport.body)).toContain('NotoNastaliqUrdu');
  await expect(sectionExport.result).toContainText('0 missing glyphs');

  // ── AC2: one page per teacher, same A4 portrait sheet ────────────────
  const teacherExport = await generate(page, 'teacher', sectionExport.href);
  expect(pdfPageCount(teacherExport.body)).toBe(2);
  expect(pdfFirstMediaBox(teacherExport.body).width).toBe(A4_PORTRAIT_WIDTH_PT);

  // ── AC3: the master grid is A3 landscape ────────────────────────────
  const masterExport = await generate(page, 'master', teacherExport.href);
  const masterBox = pdfFirstMediaBox(masterExport.body);
  expect(masterBox.width).toBe(A3_LANDSCAPE_WIDTH_PT);
  expect(masterBox.width).toBeGreaterThan(masterBox.height);
  expect(pdfPageCount(masterExport.body)).toBe(6);

  // Every run is recorded and re-downloadable from the job list.
  const jobCard = page.getByTestId(/^timetable-export-job-/).first();
  await expect(jobCard).toBeVisible();
  await expect(jobCard).toContainText('Master grid');
  await expect(jobCard.getByRole('link', { name: 'Download' })).toBeVisible();
});

test('AC6: a teacher can only export their own single-page sheet', async ({ page }) => {
  const { ayeshaEmail } = await seed();
  await signIn(page, ayeshaEmail);

  await page.goto('/academic-setup/timetable-export');
  await page.waitForLoadState('networkidle');

  // The section and master layouts are not even offered — and
  // request_timetable_export() refuses them regardless of what the form
  // posts (proven in supabase/tests/database/timetable_print_and_export).
  await page.getByTestId('timetable-export-layout-trigger').click();
  await expect(page.getByTestId('timetable-export-layout-teacher')).toBeVisible();
  await expect(page.getByTestId('timetable-export-layout-section')).toHaveCount(0);
  await expect(page.getByTestId('timetable-export-layout-master')).toHaveCount(0);
  await page.keyboard.press('Escape');

  await page.getByTestId('timetable-export-run-button').click();
  const result = page.getByTestId('timetable-export-latest-result');
  await expect(result).toBeVisible({ timeout: 60_000 });
  await expect(result).toContainText('1 page');

  const href = await page.getByTestId('timetable-export-download-link').getAttribute('href');
  const response = await page.request.get(href!);
  expect(response.ok()).toBe(true);
  const body = Buffer.from(await response.body());
  expect(pdfPageCount(body)).toBe(1);
});
