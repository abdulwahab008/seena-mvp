import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I02: exam subject and component setup, through the real UI.
//
// AC1's "total max 85 is displayed and the grid renders TWO component
// columns" and AC4's "grid is DISABLED with 'exam setup pending — contact
// the exam office'" are statements about the MARK ENTRY grid, so they are
// asserted on the real one at /exams/marks. Until FR-I12 that grid did not
// exist and this spec drove a read-only preview panel on the setup screen
// instead; the panel is gone and the assertions moved rather than being
// duplicated across two surfaces.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const SETUP_PENDING = 'exam setup pending — contact the exam office';
const PASS_EXCEEDS_MAX = 'pass marks cannot exceed maximum marks';

/**
 * Seeds an Exam Controller with the curriculum AC1 and AC4 are written
 * about: Class 9 Pre-Medical Biology (stream-specific) and Class 9 Computer
 * Science (in the curriculum, never configured for the exam), plus an
 * activated First Term to hang the configuration off.
 */
async function seedCurriculum() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `controller-${runId}@exam-subject-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `exam-subject-e2e-${runId}`,
    p_legal_name: `Exam Subject E2E School ${runId}`,
    p_owner_email: `owner-${runId}@exam-subject-e2e.test`,
  });
  if (e1) throw e1;

  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin.from('app_user').insert({
    user_id: created.user.id,
    tenant_id: tenantId as string,
    app_role: 'exam_controller',
    full_name: 'E2E Exam Controller',
  });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin
    .from('academic_session')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .single();
  await admin.from('user_campus').insert({
    user_id: created.user.id,
    tenant_id: tenantId as string,
    campus_id: campus!.id,
  });

  const { data: class9 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '9')
    .single();

  // Curriculum and stream go in through the service role: FR-E04/E05/E06
  // have their own screens and their own e2e coverage, and this test is
  // about what FR-I02 does with them, not about re-driving them.
  const { data: bio } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'BIO', name_en: 'Biology', name_ur: 'حیاتیات' })
    .select('id')
    .single();
  const { data: cs } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'CS', name_en: 'Computer Science', name_ur: 'کمپیوٹر' })
    .select('id')
    .single();
  const { data: stream } = await admin
    .from('stream')
    .insert({
      tenant_id: tenantId as string,
      code: 'PRE_MED',
      name_en: 'Pre-Medical',
      board: 'FBISE',
      applies_from_ordinal: 10,
    })
    .select('id')
    .single();

  await admin.from('class_subject').insert([
    {
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      stream_id: stream!.id,
      subject_id: bio!.id,
      weekly_periods: 6,
    },
    {
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      subject_id: cs!.id,
      weekly_periods: 4,
    },
  ]);

  const { data: section } = await admin
    .from('class_section')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: class9!.id,
      stream_id: stream!.id,
      name: 'PM',
      capacity: 35,
    })
    .select('id')
    .single();

  const { data: term } = await admin
    .from('exam_term')
    .insert({
      tenant_id: tenantId as string,
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

  return { email, password, sectionId: section!.id, termId: term!.id };
}

test('an Exam Controller configures Class 9 Pre-Medical Biology as theory plus practical, and Computer Science stays pending', async ({
  page,
}) => {
  const { email, password } = await seedCurriculum();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/exams/subjects');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('exam-subject-empty')).toBeVisible();

  // AC4 first, so "pending" is demonstrably the state BEFORE any setup
  // exists rather than a message that only ever shows for one subject.
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — PM' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Biology' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-disabled')).toBeVisible();
  await expect(page.getByTestId('mark-entry-pending-message')).toHaveText(SETUP_PENDING);

  await page.goto('/exams/subjects');
  await page.waitForLoadState('networkidle');

  // AC2: practical pass 7 out of a maximum of 5 is refused.
  await page.getByTestId('class-subject-select').selectOption({ label: 'Class 9 Pre-Medical — Biology' });
  await page.getByLabel('Max marks', { exact: false }).first().fill('65');
  await page.getByLabel('Pass marks', { exact: false }).first().fill('23');
  await page.getByTestId('add-component').click();
  await page.locator('#component-1').selectOption('practical');
  await page.locator('#maxMarks-1').fill('5');
  await page.locator('#passMarks-1').fill('7');

  await expect(page.getByTestId('draft-pass-error')).toHaveText(PASS_EXCEEDS_MAX);
  await page.getByTestId('save-exam-subject').click();
  // Scoped to the toast region, because the inline hint above already shows
  // the same sentence and a bare text match would pass without the save ever
  // being refused. upsert_exam_subject() raises this wording too — that path
  // is asserted in pgTAP, where no client schema can answer first.
  await expect(
    page.getByRole('region', { name: /Notifications/ }).getByText(PASS_EXCEEDS_MAX),
  ).toBeVisible();
  await expect(page.getByTestId('exam-subject-empty')).toBeVisible();

  // AC1: correct the practical to max 20 pass 7, and the total reads 85.
  await page.locator('#maxMarks-1').fill('20');
  await expect(page.getByTestId('draft-total-max')).toHaveText('85');
  await expect(page.getByTestId('draft-pass-error')).toHaveCount(0);
  await page.getByTestId('save-exam-subject').click();
  await expect(page.getByText('Exam setup saved.')).toBeVisible();

  await expect(page.getByTestId('exam-subject-total-Biology')).toHaveText('85');
  await expect(page.getByTestId('exam-subject-row-Biology')).toContainText('Pre-Medical');
  await expect(page.getByTestId('exam-subject-row-Biology')).toContainText('theory 65/23, practical 20/7');

  // AC1: the mark entry grid now renders TWO component columns.
  await page.goto('/exams/marks');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('mark-section-select').selectOption({ label: 'Class 9 — PM' });
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Biology' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toBeVisible();
  await expect(page.getByTestId('mark-entry-total-max')).toHaveText('85');
  await expect(page.getByTestId('mark-entry-column-theory')).toContainText('max 65 / pass 23');
  await expect(page.getByTestId('mark-entry-column-practical')).toContainText('max 20 / pass 7');
  // Student + FR-I11's exam status + one column per component.
  await expect(page.getByTestId('mark-entry-grid').locator('thead th')).toHaveCount(4);

  // AC4: Computer Science, which nobody configured, is still disabled with
  // the exact message — in the same term, for the same section.
  await page.getByTestId('mark-subject-select').selectOption({ label: 'Computer Science' });
  await page.getByTestId('open-mark-entry').click();
  await expect(page.getByTestId('mark-entry-grid')).toHaveCount(0);
  await expect(page.getByTestId('mark-entry-disabled')).toBeVisible();
  await expect(page.getByTestId('mark-entry-pending-message')).toHaveText(SETUP_PENDING);
});
