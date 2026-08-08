import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@unmarked-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `unmarked-e2e-${runId}`,
    p_legal_name: `Unmarked E2E School ${runId}`,
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

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { error: e4 } = await admin
    .from('attendance_policy')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, start_time: '08:00', late_threshold_minutes: 15, lock_window_hours: 24 });
  if (e4) throw e4;

  const sectionIds: Record<string, string> = {};
  for (const name of ['A', 'B', 'C']) {
    const { data: section, error } = await admin
      .from('class_section')
      .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name, capacity: 30 })
      .select('id')
      .single();
    if (error) throw error;
    sectionIds[name] = section!.id as string;
  }

  return { ownerEmail, password, campusId: campus!.id as string, sectionIds };
}

test('an owner runs the unmarked-attendance check and sees fully-marked excluded, partial and zero-marked flagged distinctly, with no re-flag on a second run', async ({
  page,
}) => {
  const { ownerEmail, password, sectionIds } = await seedTenant();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  // Two students in each section — C is enrolled the same as the others
  // but its register is simply never opened at all, the common "forgot
  // entirely" case. A section with nobody enrolled would be vacuously
  // "fully marked" (0 marked of 0 expected), so it needs real students
  // to actually surface as a gap.
  const enrolByLabel: Record<string, string> = {};
  for (const section of ['A', 'B', 'C'] as const) {
    for (const suffix of ['1', '2'] as const) {
      const name = `${section}${suffix} Kid`;
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
      await page.getByRole('option', { name: `Class 1 · ${section}` }).click();
      await page.getByRole('button', { name: 'Enrol into section' }).click();
      await expect(page.getByText('Enrolled.')).toBeVisible();

      const { data: enrolment } = await admin.from('enrolment').select('id').eq('student_id', studentId).single();
      enrolByLabel[name] = enrolment!.id as string;
    }
  }

  const today = new Date().toISOString().slice(0, 10);

  // Section A: the genuine UI zero-touch path — load, save, everyone
  // defaults to present. This is what "fully marked" looks like for real.
  await page.goto('/attendance/register');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('register-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByTestId('register-date').fill(today);
  await page.getByTestId('register-load').click();
  await expect(page.locator('[data-testid^="register-row-"]')).toHaveCount(2);
  await page.getByTestId('register-save').click();
  await expect(page.getByText('Register saved — 2 student(s).')).toBeVisible();

  // Section B: a genuinely partial submission — only one of its two
  // students gets a row. rpc_bulk_mark_attendance() (what the UI itself
  // calls) always auto-completes every active enrolment to 'present', so
  // this can only happen via a direct call to the lower-level function it
  // wraps, exactly the gap this FR's own migration header describes.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;
  const { error: partialError } = await ownerClient.rpc('save_attendance_register', {
    p_section_id: sectionIds.B,
    p_attendance_date: today,
    p_marks: [{ enrolment_id: enrolByLabel['B1 Kid'], status: 'present' }],
  });
  if (partialError) throw partialError;

  // AC1/AC4: run the check from the real screen.
  await page.goto('/attendance/unmarked');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('unmarked-date').fill(today);
  await page.getByTestId('unmarked-run').click();

  await expect(page.getByTestId(`unmarked-row-${sectionIds.A}`)).not.toBeVisible();
  await expect(page.getByTestId(`unmarked-status-${sectionIds.B}`)).toHaveText('partially marked (1/2)');
  await expect(page.getByTestId(`unmarked-status-${sectionIds.C}`)).toHaveText('unmarked');

  // AC3: running it again for the exact same date shows nothing — both
  // gaps were already logged by the first run.
  await page.getByTestId('unmarked-run').click();
  await expect(page.getByTestId('unmarked-none')).toBeVisible();
  await expect(page.locator('[data-testid^="unmarked-row-"]')).toHaveCount(0);
});
