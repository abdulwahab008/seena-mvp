import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithRankedApplicantAndPanel() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@scorecard-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `scorecard-e2e-${runId}`,
    p_legal_name: `Scorecard E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  async function createPanelist(name: string) {
    const panelEmail = `${name.toLowerCase().replace(/\s+/g, '-')}-${runId}@scorecard-e2e.test`;
    const { data: user, error } = await admin.auth.admin.createUser({ email: panelEmail, password, email_confirm: true });
    if (error || !user.user) throw error ?? new Error('panel user creation failed');
    const { error: e } = await admin
      .from('app_user')
      .insert({ user_id: user.user.id, tenant_id: tenantId as string, app_role: 'principal', full_name: name });
    if (e) throw e;
    return user.user.id;
  }

  const panel1UserId = await createPanelist('Panel One');
  const panel2UserId = await createPanelist('Panel Two');

  // One seat, one candidate — the candidate ranks 1st for 1 seat, so a
  // 'reject' recommendation on their scorecard is a merit override.
  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 1,
  });
  if (e4) throw e4;

  const { data: enquiry } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'Ranked Candidate',
      dob: '2020-01-01',
      class_applied_id: classLevel!.id,
      parent_name: 'Parent One',
      phone_e164: '+923001111111',
      whatsapp_opt_in: false,
      source: 'walk_in',
      status: 'converted',
    })
    .select('id')
    .single();
  const { data: application } = await admin
    .from('admission_application')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_id: enquiry!.id,
      application_no: 'APP-2026-00001',
      class_applied_id: classLevel!.id,
      status: 'submitted',
    })
    .select('id')
    .single();

  const { data: sitting } = await admin
    .from('admission_test_sitting')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      starts_at: '2026-08-05 09:00:00+05',
      capacity: 5,
    })
    .select('id')
    .single();
  const { data: candidate } = await admin
    .from('admission_test_candidate')
    .insert({ tenant_id: tenantId as string, sitting_id: sitting!.id, application_id: application!.id, seat_no: 1 })
    .select('id')
    .single();
  const { error: e5 } = await admin
    .from('admission_test_score')
    .insert({ tenant_id: tenantId as string, candidate_id: candidate!.id, subject_code: 'total', obtained: 80, total: 100 });
  if (e5) throw e5;

  return { email, password };
}

test('an owner scores an interview, a merit-overriding recommendation needs a justification, and both panel scorecards show the mean', async ({
  page,
}) => {
  const { email, password } = await seedOwnerWithRankedApplicantAndPanel();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/admissions/interviews');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('interview-application-trigger').click();
  await page.getByRole('option', { name: /Ranked Candidate/ }).click();
  await page.getByTestId('interview-panel-trigger').click();
  await page.getByRole('option', { name: /Panel One/ }).click();
  await page.locator('#interviewStartsAt').fill('2026-08-15T09:00');
  await page.locator('#interviewEndsAt').fill('2026-08-15T09:20');
  await page.getByRole('button', { name: 'Book interview' }).click();
  await expect(page.getByText('Interview booked.')).toBeVisible();

  await page.getByTestId('interview-application-trigger').click();
  await page.getByRole('option', { name: /Ranked Candidate/ }).click();
  await page.getByTestId('interview-panel-trigger').click();
  await page.getByRole('option', { name: /Panel Two/ }).click();
  await page.locator('#interviewStartsAt').fill('2026-08-15T10:00');
  await page.locator('#interviewEndsAt').fill('2026-08-15T10:20');
  await page.getByRole('button', { name: 'Book interview' }).click();
  await expect(page.getByText('Interview booked.')).toBeVisible();

  const rows = page.locator('[data-testid^="interview-row-"]').filter({ hasText: 'Ranked Candidate' });
  await expect(rows).toHaveCount(2);
  const row1 = rows.filter({ hasText: 'Panel One' });
  const row2 = rows.filter({ hasText: 'Panel Two' });

  async function fillScores(row: ReturnType<typeof row1>, communication: string, confidence: string, academic: string, parental: string, overall: string) {
    await row.locator('[data-testid^="scorecard-communication-"]').fill(communication);
    await row.locator('[data-testid^="scorecard-confidence-"]').fill(confidence);
    await row.locator('[data-testid^="scorecard-academic_readiness-"]').fill(academic);
    await row.locator('[data-testid^="scorecard-parental_engagement-"]').fill(parental);
    await row.locator('[data-testid^="scorecard-overall_impression-"]').fill(overall);
  }

  // AC: rejecting a candidate who ranks 1st of 1 for the class's only
  // seat is a merit override — refused without a justification.
  await fillScores(row1, '2', '2', '2', '2', '2');
  await row1.locator('[data-testid^="scorecard-recommendation-"]').click();
  await page.getByRole('option', { name: 'reject', exact: true }).click();
  await row1.locator('[data-testid^="scorecard-submit-"]').click();
  await expect(page.getByText(/justification of at least 20 characters is required/)).toBeVisible();

  await row1.locator('[data-testid^="scorecard-justification-"]').fill('The child was unable to answer basic questions during the session.');
  await row1.locator('[data-testid^="scorecard-submit-"]').click();
  await expect(page.getByText('Scorecard submitted.')).toBeVisible();

  // The second panel member's scorecard, no override, no justification
  // needed.
  await fillScores(row2, '4', '5', '4', '5', '4');
  await row2.locator('[data-testid^="scorecard-recommendation-"]').click();
  await page.getByRole('option', { name: 'accept', exact: true }).click();
  await row2.locator('[data-testid^="scorecard-submit-"]').click();
  await expect(page.getByText('Scorecard submitted.')).toBeVisible();

  // AC: both scorecards, and the mean of their criteria, are displayed
  // together.
  await row1.getByRole('button', { name: 'View scorecards' }).click();
  const comparison = row1.locator('[data-testid^="scorecard-comparison-"]');
  await expect(comparison).toContainText('Panel One');
  await expect(comparison).toContainText('Panel Two');
  await expect(comparison).toContainText('communication:3');
});
