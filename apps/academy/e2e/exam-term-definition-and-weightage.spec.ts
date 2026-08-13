import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-I01: exam term definition and weightage, driven through the real UI by
// an Exam Controller.
//
// AC2 is the reason this test exists in the browser at all: the acceptance
// criteria assert the wording of the refusal, and a message is only really
// asserted where a person reads it. The string below is the one the
// database raises, carried to the screen untranslated.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const WEIGHTAGE_REFUSAL = 'Term weightage must total 100.00%, currently 90.00%';
const FROZEN_REFUSAL = 'exam term weightage is locked by approved marks — raise a result-recompute request';

async function seedExamController() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `controller-${runId}@exam-term-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `exam-term-e2e-${runId}`,
    p_legal_name: `Exam Term E2E School ${runId}`,
    p_owner_email: `owner-${runId}@exam-term-e2e.test`,
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

  // The Controller is posted to the tenant's only campus, so
  // app.auth_campus_ids() covers the campus this page derives.
  const { data: campus, error: e4 } = await admin
    .from('campus')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .single();
  if (e4 || !campus) throw e4 ?? new Error('campus lookup failed');
  const { error: e5 } = await admin
    .from('user_campus')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus.id });
  if (e5) throw e5;

  return { email, password };
}

type TermInput = { code: string; name: string; position: number; weight: string; counting?: boolean };

async function submitTerm(page: import('@playwright/test').Page, opts: TermInput) {
  await page.getByLabel('Code').fill(opts.code);
  await page.getByLabel('Term name').fill(opts.name);
  await page.getByLabel('Position').fill(String(opts.position));
  await page.getByLabel('Weightage %').fill(opts.weight);
  const counting = page.getByLabel('Counts toward annual');
  if (opts.counting === false) await counting.uncheck();
  else await counting.check();
  await page.getByTestId('save-exam-term').click();
}

async function addTerm(page: import('@playwright/test').Page, opts: TermInput) {
  await submitTerm(page, opts);
  await expect(page.getByText(`${opts.name} saved.`)).toBeVisible();
  // The form clears itself inside the same transition that revalidates the
  // page, so the clear can land a beat after the toast. Wait for it, or the
  // next term's first keystrokes get wiped by a late reset.
  await expect(page.getByLabel('Code')).toHaveValue('');
}

test('an Exam Controller is refused an incomplete term set, fixes it, activates, and can no longer re-weight a locked term', async ({
  page,
}) => {
  const { email, password } = await seedExamController();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/exams/terms');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('exam-term-empty')).toBeVisible();

  // AC2: the set the acceptance criteria call out — 25 / 15 / 50.
  await addTerm(page, { code: 'T1', name: 'First Term', position: 1, weight: '25' });
  await addTerm(page, { code: 'MID', name: 'Mid Term', position: 2, weight: '15' });
  await addTerm(page, { code: 'FIN', name: 'Final Term', position: 3, weight: '50' });

  await expect(page.getByTestId('exam-term-counting-total')).toHaveText('90.00%');
  await page.getByTestId('activate-terms').click();

  // The sentence, word for word, where a person reads it.
  await expect(page.getByText(WEIGHTAGE_REFUSAL)).toBeVisible();

  // AC2: and NO term changed status.
  for (const code of ['T1', 'MID', 'FIN']) {
    await expect(page.getByTestId(`exam-term-status-${code}`)).toHaveText('Draft');
  }

  // AC1: correct the Final Term to 60 and add the 0% non-counting Pre-Board.
  await addTerm(page, { code: 'FIN', name: 'Final Term', position: 3, weight: '60' });
  await addTerm(page, { code: 'PB', name: 'Pre-Board', position: 4, weight: '0', counting: false });

  await expect(page.getByTestId('exam-term-counting-total')).toHaveText('100.00%');
  await page.getByTestId('activate-terms').click();
  await expect(page.getByText('4 term(s) activated.')).toBeVisible();

  // AC1: all four terms — the 0% Pre-Board included — are now selectable in
  // mark entry.
  for (const code of ['T1', 'MID', 'FIN', 'PB']) {
    await expect(page.getByTestId(`exam-term-status-${code}`)).toHaveText('Active — selectable in mark entry');
  }
  await expect(page.getByTestId('exam-term-weight-PB')).toHaveText('0.00%');

  // AC4: a school that runs weekly tests flags the term as not counting. It
  // carries a real 10% weight, and the 100% total does not move.
  await addTerm(page, { code: 'WK', name: 'Weekly Tests', position: 5, weight: '10', counting: false });
  await expect(page.getByTestId('exam-term-counting-total')).toHaveText('100.00%');
  await expect(page.getByTestId('exam-term-row-WK')).toContainText('No — excluded from the 100% total');
  await page.getByTestId('activate-terms').click();
  await expect(page.getByText('1 term(s) activated.')).toBeVisible();
  await expect(page.getByTestId('exam-term-status-WK')).toHaveText('Active — selectable in mark entry');

  // AC3: marks get approved against the Final Term. FR-I16 will call
  // lock_exam_term() itself; until it exists this control stands in for it.
  await page.getByTestId('exam-term-lock-FIN').click();
  await expect(page.getByText('Term locked.')).toBeVisible();
  await expect(page.getByTestId('exam-term-status-FIN')).toHaveText('Locked by approved marks');

  // AC3: re-weighting it is now BLOCKED, and the message says where to go.
  await submitTerm(page, { code: 'FIN', name: 'Final Term', position: 3, weight: '55', counting: true });
  await expect(page.getByText(FROZEN_REFUSAL)).toBeVisible();
  await expect(page.getByTestId('exam-term-weight-FIN')).toHaveText('60.00%');
});
