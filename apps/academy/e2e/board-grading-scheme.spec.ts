import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-J01: board grading scheme configuration, through the real UI.
//
//   AC1  the published FBISE set saves, validates and activates, and it is
//        the scale Class 9 and Class 12 both resolve to.
//   AC2  bands 70-79 beside 80-100 are refused naming 79.00-80.00 — on the
//        screen while the controller is typing, and again in the database.
//   AC3  a Cambridge scheme sits beside the FBISE one and a section tagged
//        Cambridge resolves to it, with no code change.
//   AC4  an activated scheme's bands are frozen, and "Start a new version"
//        carries them into a new effective-dated draft.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const admin = () => createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

/**
 * One campus, two Class 9 sections and a Class 12 section. One of the Class 9
 * sections is tagged Cambridge through its stream, which is where a board tag
 * already lives in this schema — AC3 turns on that and nothing else.
 */
async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@grading-e2e.test`;
  const controllerEmail = `controller-${runId}@grading-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `grading-e2e-${runId}`,
    p_legal_name: `Grading E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: session } = await db.from('academic_session').select('id, starts_on').eq('tenant_id', tenant).single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller', fullName: string) => {
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
  await makeUser(controllerEmail, 'exam_controller', 'Nusrat Jahan');

  const signedIn = async (email: string) => {
    const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error } = await client.auth.signInWithPassword({ email, password: PASSWORD });
    if (error) throw error;
    return client;
  };
  const ownerClient = await signedIn(ownerEmail);
  const controllerClient = await signedIn(controllerEmail);

  const { data: class9 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '9').single();
  const { data: class12 } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '12').single();

  const makeSection = async (classLevelId: string, name: string) => {
    const { data, error } = await ownerClient.rpc('create_section', {
      p_campus_id: campus!.id,
      p_session_id: session!.id,
      p_class_level_id: classLevelId,
      p_name: name,
      p_capacity: 40,
    });
    if (error) throw error;
    return data as string;
  };
  const sec9 = await makeSection(class9!.id, 'A');
  const sec9Cie = await makeSection(class9!.id, 'O');
  const sec12 = await makeSection(class12!.id, 'A');

  const { data: stream, error: streamError } = await ownerClient.rpc('create_stream', {
    p_code: 'CIE9',
    p_name_en: 'Cambridge',
    p_name_ur: 'کیمبرج',
    p_board: 'CAMBRIDGE',
    p_applies_from_ordinal: 10,
  });
  if (streamError) throw streamError;
  const { error: tagError } = await ownerClient.rpc('set_section_stream', {
    p_section_id: sec9Cie,
    p_stream_id: stream as string,
  });
  if (tagError) throw tagError;

  return { controllerEmail, controllerClient, sec9, sec9Cie, sec12, gradeOn: session!.starts_on as string };
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

/** Fills the editor's band rows from the top down. */
async function fillBands(
  page: import('@playwright/test').Page,
  rows: { label: string; min: string; max: string }[],
) {
  for (const [i, row] of rows.entries()) {
    await page.getByTestId('grading-band-add').click();
    await page.getByTestId(`grading-band-label-${i}`).fill(row.label);
    await page.getByTestId(`grading-band-min-${i}`).fill(row.min);
    await page.getByTestId(`grading-band-max-${i}`).fill(row.max);
  }
}

test('a board grade scale is configured, validated for coverage, frozen on activation and versioned forward', async ({
  page,
}) => {
  const { controllerEmail, controllerClient, sec9, sec9Cie, sec12, gradeOn } = await seed();

  await signIn(page, controllerEmail);
  await page.goto('/exams/grading');
  await page.waitForLoadState('networkidle');

  // Nothing is assumed on the school's behalf — there is no seeded scale.
  await expect(page.getByTestId('grading-none')).toBeVisible();

  // ── AC2: a gap is named before anything is written ─────────────────────
  await page.getByTestId('grading-new-scheme').click();
  await page.getByTestId('grading-name').fill('Gapped');
  await page.getByTestId('grading-effective-from').fill('2025-04-01');
  await fillBands(page, [
    { label: 'A1', min: '80', max: '100' },
    { label: 'A', min: '70', max: '79' },
    { label: 'F', min: '0', max: '69.99' },
  ]);
  await expect(page.getByTestId('grading-coverage-error')).toHaveText('grading bands leave 79.00-80.00 uncovered');
  await expect(page.getByTestId('grading-save')).toBeDisabled();

  // The screen is a convenience; the database is the gate. The same set sent
  // straight to the RPC is refused with the same sentence.
  const { error: gapError } = await controllerClient.rpc('save_grading_scheme', {
    p_board: 'PUNJAB',
    p_name: 'Gapped',
    p_effective_from: '2025-04-01',
    p_bands: [
      { grade_label: 'A1', min_pct: 80, max_pct: 100 },
      { grade_label: 'A', min_pct: 70, max_pct: 79 },
      { grade_label: 'F', min_pct: 0, max_pct: 69.99 },
    ],
  });
  expect(gapError?.message).toContain('grading bands leave 79.00-80.00 uncovered');

  // ── AC1: the published FBISE set ───────────────────────────────────────
  await page.getByTestId('grading-preset-fbise').click();
  await page.getByTestId('grading-name').fill('FBISE 2025');
  await expect(page.getByTestId('grading-coverage-ok')).toBeVisible();
  await page.getByTestId('grading-save').click();

  const scheme = page.getByTestId('grading-scheme-FBISE-v1');
  await expect(scheme).toBeVisible();
  await expect(scheme).toContainText('draft');
  // The published boundaries, as the board prints them.
  await expect(scheme.getByRole('row').filter({ hasText: 'A1' })).toContainText('80.00%');
  await expect(scheme.getByRole('row').filter({ hasText: 'A1' })).toContainText('100.00%');

  await scheme.getByTestId(/^grading-activate-/).click();
  await expect(scheme).toContainText('active');
  await expect(scheme.getByTestId(/^grading-frozen-/)).toBeVisible();

  // Both classes resolve to it: a scale is the board's, not the class's.
  const resolve = async (sectionId: string, onDate: string) => {
    const { data, error } = await controllerClient.rpc('fn_grading_scheme_for_section', {
      p_section_id: sectionId,
      p_on_date: onDate,
    });
    if (error) throw error;
    return data as string | null;
  };
  const fbise = await resolve(sec9, gradeOn);
  expect(fbise).toBeTruthy();
  expect(await resolve(sec12, gradeOn)).toBe(fbise);

  // ── AC3: Cambridge beside FBISE ────────────────────────────────────────
  await page.getByTestId('grading-new-scheme').click();
  await page.getByTestId('grading-board-select').selectOption('CAMBRIDGE');
  await page.getByTestId('grading-name').fill('Cambridge IGCSE');
  await page.getByTestId('grading-effective-from').fill('2025-04-01');
  await fillBands(page, [
    { label: 'A*', min: '90', max: '100' },
    { label: 'A', min: '80', max: '89.99' },
    { label: 'B', min: '70', max: '79.99' },
    { label: 'C', min: '60', max: '69.99' },
    { label: 'D', min: '50', max: '59.99' },
    { label: 'E', min: '40', max: '49.99' },
    { label: 'U', min: '0', max: '39.99' },
  ]);
  // Cambridge U is ungraded: no GPA point, rather than a zero that would
  // average in.
  await page.getByTestId('grading-band-gpa-6').fill('');
  await page.getByTestId('grading-band-pass-6').uncheck();
  await expect(page.getByTestId('grading-coverage-ok')).toBeVisible();
  await page.getByTestId('grading-save').click();

  const cieScheme = page.getByTestId('grading-scheme-CAMBRIDGE-v1');
  await expect(cieScheme).toBeVisible();
  await cieScheme.getByTestId(/^grading-activate-/).click();
  await expect(cieScheme).toContainText('active');

  const cie = await resolve(sec9Cie, gradeOn);
  expect(cie).toBeTruthy();
  expect(cie).not.toBe(fbise);
  // The FBISE section beside it is unaffected — both schemes coexist and the
  // section's tag is what picks between them.
  expect(await resolve(sec9, gradeOn)).toBe(fbise);

  const gradeFor = async (schemeId: string, pct: number) => {
    const { data, error } = await controllerClient.rpc('fn_grade_for_percentage', {
      p_scheme_id: schemeId,
      p_pct: pct,
    });
    if (error) throw error;
    return (data as { grade_label: string } | null)?.grade_label ?? null;
  };
  expect(await gradeFor(cie!, 85)).toBe('A');
  expect(await gradeFor(fbise!, 85)).toBe('A1');
  // The boundary FR-J02 rides on, end to end.
  expect(await gradeFor(fbise!, 32.995)).toBe('E');
  expect(await gradeFor(fbise!, 32.994)).toBe('F');

  // ── AC4: frozen, then versioned forward ────────────────────────────────
  const { error: freezeError } = await controllerClient.rpc('save_grading_scheme', {
    p_board: 'FBISE',
    p_name: 'FBISE 2025',
    p_effective_from: '2025-04-01',
    p_bands: [
      { grade_label: 'A1', min_pct: 85, max_pct: 100 },
      { grade_label: 'F', min_pct: 0, max_pct: 84.99 },
    ],
    p_scheme_id: fbise,
  });
  expect(freezeError?.message).toContain('grading scheme is in use');

  await page.getByTestId(`grading-new-version-date-${fbise}`).fill('2026-04-01');
  await page.getByTestId(`grading-new-version-${fbise}`).click();

  const v2 = page.getByTestId('grading-scheme-FBISE-v2');
  await expect(v2).toBeVisible();
  await expect(v2).toContainText('draft');
  // The bands come across rather than starting from nothing.
  await expect(v2.getByRole('row').filter({ hasText: 'A1' })).toContainText('80.00%');
  await v2.getByTestId(/^grading-activate-/).click();
  await expect(v2).toContainText('active');

  // A 2025 result still resolves to v1 — the whole point of effective-dating.
  expect(await resolve(sec9, '2025-09-01')).toBe(fbise);
  expect(await resolve(sec9, '2026-09-01')).not.toBe(fbise);
});
