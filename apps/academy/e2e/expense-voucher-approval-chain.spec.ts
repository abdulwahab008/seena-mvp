import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

// FR-L11 AC4. Playwright talks to `next start` directly, so no proxy adds an
// x-forwarded-for and the column would be NULL for every request. Setting the
// header here stands in for the trusted ingress a real deployment sits behind
// — and demonstrates the limitation the migration header states plainly: a
// client can send this value, so it is evidence only when a proxy overwrites
// it. WHO approved is the JWT's, which no header can touch.
const FORWARDED_IP = '203.0.113.9';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

async function seedTenant() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const accountantEmail = `accountant-${runId}@expense-e2e.test`;
  const principalEmail = `principal-${runId}@expense-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `expense-e2e-${runId}`,
    p_legal_name: `Expense E2E School ${runId}`,
    p_owner_email: `owner-${runId}@expense-e2e.test`,
  });
  if (e1) throw e1;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenantId as string).single();

  const makeUser = async (email: string, role: 'accountant' | 'principal', name: string) => {
    const { data: user, error } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (error || !user.user) throw error ?? new Error(`${role} creation failed`);
    const { error: eu } = await db
      .from('app_user')
      .insert({ user_id: user.user.id, tenant_id: tenantId as string, app_role: role, full_name: name });
    if (eu) throw eu;
    // FR-A12: a campus-scoped role needs its campus in the JWT.
    const { error: ec } = await db
      .from('user_campus')
      .insert({ tenant_id: tenantId as string, user_id: user.user.id, campus_id: campus!.id });
    if (ec) throw ec;
    return user.user.id;
  };

  await makeUser(accountantEmail, 'accountant', 'E2E Accountant');
  await makeUser(principalEmail, 'principal', 'E2E Principal');

  return { tenantId: tenantId as string, campusId: campus!.id as string, accountantEmail, principalEmail };
}

async function signIn(page: Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function selectOption(page: Page, trigger: string, option: string) {
  await page.getByTestId(trigger).click();
  await page.getByTestId(option).click();
}

async function submitVoucher(
  page: Page,
  opts: { payee: string; amount: string; date: string; head?: string; narrative?: string; attach?: boolean },
) {
  await selectOption(page, 'voucher-head-trigger', `voucher-head-option-${opts.head ?? 'UTILITIES'}`);
  await page.getByTestId('voucher-payee-input').fill(opts.payee);
  await page.getByTestId('voucher-amount-input').fill(opts.amount);
  await page.getByTestId('voucher-date-input').fill(opts.date);
  if (opts.narrative) await page.getByTestId('voucher-narrative-input').fill(opts.narrative);
  if (opts.attach) {
    await page.getByTestId('voucher-attachment-input').setInputFiles({
      name: 'bill.pdf',
      mimeType: 'application/pdf',
      buffer: Buffer.from('%PDF-1.4 electricity bill'),
    });
  }
  await page.getByTestId('voucher-submit-button').click();
  await expect(page.getByTestId('voucher-submit-result')).toBeVisible();
}

test('a voucher above the limit reaches the Principal, cannot be paid until approved, and a rejection locks it', async ({
  page,
}) => {
  const { tenantId, accountantEmail, principalEmail } = await seedTenant();
  const db = admin();
  await page.setExtraHTTPHeaders({ 'x-forwarded-for': FORWARDED_IP });

  const today = new Date().toISOString().slice(0, 10);

  await signIn(page, accountantEmail);
  await page.goto('/expenses/vouchers');
  await page.waitForLoadState('networkidle');

  // ── AC1: PKR 150,000 is routed to the Principal ────────────────────────
  await submitVoucher(page, { payee: 'K-Electric', amount: '150000', date: today, narrative: 'August bill', attach: true });
  await expect(page.getByTestId('voucher-submit-result')).toContainText('Routed to Principal for approval');

  const { data: bigRow } = await db
    .from('expense_voucher')
    .select('id, status, required_approver_role, amount_paisa, attachment_path')
    .eq('tenant_id', tenantId)
    .eq('payee_name', 'K-Electric')
    .single();
  expect(bigRow!.status).toBe('pending_approval');
  expect(bigRow!.required_approver_role).toBe('principal');
  // Money is paisa as bigint, this codebase's convention throughout.
  expect(bigRow!.amount_paisa).toBe(15000000);
  expect(bigRow!.attachment_path).toBeTruthy();

  const bigId = bigRow!.id;
  await expect(page.getByTestId(`voucher-status-${bigId}`)).toHaveText('Awaiting approval');
  await expect(page.getByTestId(`voucher-required-${bigId}`)).toHaveText('Requires: Principal');
  // AC1: there is no pay button at all, and the database refuses one anyway.
  await expect(page.getByTestId(`voucher-pay-${bigId}`)).toHaveCount(0);
  await expect(page.getByTestId(`voucher-unpayable-${bigId}`)).toContainText('Cannot be paid until Principal approves');

  // The bill is readable only through a signed URL, and only to somebody the
  // voucher's own scope lets read it.
  // The popup may end as a download rather than a navigation, so the request
  // is what is asserted on: a signed URL was minted, which only happens if
  // expense_attachment_read_scope let this user read the object.
  const [bill] = await Promise.all([
    page.context().waitForEvent('page'),
    page.getByTestId(`voucher-bill-${bigId}`).click(),
  ]);
  const billRequest = await bill.waitForRequest(/expense-attachments/);
  expect(billRequest.url()).toContain('/storage/v1/object/sign/expense-attachments/');
  await bill.close();

  // The Accountant cannot approve their own voucher either.
  await page.goto('/expenses/approvals');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('expense-approvals-forbidden')).toBeVisible();

  // ── AC3: two PKR 20,000 vouchers for the same payee, head and date ─────
  await page.goto('/expenses/vouchers');
  await page.waitForLoadState('networkidle');
  await submitVoucher(page, { payee: 'M/s Ali Traders', amount: '20000', date: today, narrative: 'Part one' });
  await expect(page.getByTestId('voucher-submit-result')).toContainText('Self-approved');

  const { data: firstSplit } = await db
    .from('expense_voucher')
    .select('id, status')
    .eq('tenant_id', tenantId)
    .eq('narrative', 'Part one')
    .single();
  expect(firstSplit!.status).toBe('approved');

  await submitVoucher(page, { payee: 'm/s  ali traders.', amount: '20000', date: today, narrative: 'Part two' });
  await expect(page.getByTestId('voucher-submit-result')).toContainText('Routed to Principal for approval');
  await expect(page.getByTestId('voucher-submit-split')).toContainText('Flagged as a possible threshold split');

  const { data: secondSplit } = await db
    .from('expense_voucher')
    .select('id, status, required_approver_role, possible_threshold_split')
    .eq('tenant_id', tenantId)
    .eq('narrative', 'Part two')
    .single();
  expect(secondSplit!.possible_threshold_split).toBe(true);
  expect(secondSplit!.required_approver_role).toBe('principal');

  // The first one — self-approved and not yet paid — is pulled back with it.
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`voucher-status-${firstSplit!.id}`)).toHaveText('Awaiting approval');
  await expect(page.getByTestId(`voucher-split-${firstSplit!.id}`)).toContainText('Possible threshold split');
  await expect(page.getByTestId(`voucher-split-${firstSplit!.id}`)).toContainText('PKR 40,000 in total');

  // AC4: the trail explains the re-opening and keeps the superseded approval.
  await page.getByTestId(`voucher-history-toggle-${firstSplit!.id}`).click();
  const trail = page.getByTestId(`trail-${firstSplit!.id}`);
  await expect(trail).toContainText('Approved — E2E Accountant');
  await expect(trail).toContainText('Re-opened for approval');
  await expect(trail).toContainText('possible threshold split');

  // ── The Principal's queue ──────────────────────────────────────────────
  await page.context().clearCookies();
  await signIn(page, principalEmail);
  await page.goto('/expenses/approvals');
  await page.waitForLoadState('networkidle');

  await expect(page.getByTestId(`approval-row-${bigId}`)).toBeVisible();
  await expect(page.getByTestId(`approval-required-${bigId}`)).toHaveText('Requires: Principal');
  await expect(page.getByTestId(`approval-split-${secondSplit!.id}`)).toContainText('Possible threshold split');

  // AC2: a short reason will not arm the Reject button.
  await page.getByTestId(`approval-reason-${bigId}`).fill('too short');
  await expect(page.getByTestId(`approval-reject-${bigId}`)).toBeDisabled();
  await expect(page.getByTestId(`approval-reason-short-${bigId}`)).toBeVisible();
  await page.getByTestId(`approval-reason-${bigId}`).fill('');

  // ── AC1: approve, then it can be paid ─────────────────────────────────
  await page.getByTestId(`approval-reason-${bigId}`).fill('Meter reading checked against the bill.');
  await page.getByTestId(`approval-approve-${bigId}`).click();
  await expect(page.getByText('Approved — it can now be paid.')).toBeVisible();

  // AC4: the approval carries approver, role, time and the reported address.
  const { data: approvals } = await db
    .from('v_expense_voucher_approval')
    .select('approver_name, approver_role, decision, request_ip, decided_at')
    .eq('voucher_id', bigId);
  const approved = (approvals ?? []).find((a) => a.decision === 'approved');
  expect(approved?.approver_name).toBe('E2E Principal');
  expect(approved?.approver_role).toBe('principal');
  expect(approved?.request_ip).toBe(FORWARDED_IP);
  expect(approved?.decided_at).toBeTruthy();

  // ── AC2: reject the split, and it locks ───────────────────────────────
  await page.getByTestId(`approval-reason-${secondSplit!.id}`).fill('Split to dodge the approval limit.');
  await page.getByTestId(`approval-reject-${secondSplit!.id}`).click();
  await expect(page.getByText('Rejected and locked.')).toBeVisible();

  await page.goto('/expenses/vouchers?status=rejected');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`voucher-status-${secondSplit!.id}`)).toHaveText('Rejected');
  await expect(page.getByTestId(`voucher-locked-${secondSplit!.id}`)).toContainText('correct it by submitting a new voucher');
  await expect(page.getByTestId(`voucher-pay-${secondSplit!.id}`)).toHaveCount(0);

  // The database says the same thing, which is where it matters: a leaked
  // service_role key writing the column by hand is refused by the status
  // guard, not by anything this UI does or does not render.
  const { error: payRejected } = await db
    .from('expense_voucher')
    .update({ status: 'paid', paid_at: new Date().toISOString() })
    .eq('id', secondSplit!.id);
  expect(payRejected?.message).toContain('expense voucher transition refused');
  const { error: editRejected } = await db
    .from('expense_voucher')
    .update({ amount_paisa: 100 })
    .eq('id', secondSplit!.id);
  expect(editRejected?.message).toContain('expense voucher transition refused');

  // ── AC1: the approved voucher is paid by the Accountant ───────────────
  await page.context().clearCookies();
  await signIn(page, accountantEmail);
  await page.goto('/expenses/vouchers');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`voucher-status-${bigId}`)).toHaveText('Approved');
  await page.getByTestId(`voucher-pay-reference-${bigId}`).fill('CHQ-000841');
  await page.getByTestId(`voucher-pay-${bigId}`).click();
  await expect(page.getByText('Recorded as paid.')).toBeVisible();
  await expect(page.getByTestId(`voucher-status-${bigId}`)).toHaveText('Paid');
  await expect(page.getByTestId(`voucher-row-${bigId}`)).toContainText('CHQ-000841');

  // ── AC4: nothing in the trail can be changed or removed ───────────────
  const { data: trailRow } = await db
    .from('expense_voucher_approval')
    .select('id')
    .eq('voucher_id', bigId)
    .eq('decision', 'approved')
    .single();
  const { error: updateError } = await db
    .from('expense_voucher_approval')
    .update({ decision: 'rejected' })
    .eq('id', trailRow!.id);
  expect(updateError?.message).toContain('append-only');
  const { error: deleteError } = await db.from('expense_voucher_approval').delete().eq('id', trailRow!.id);
  expect(deleteError?.message).toContain('append-only');

  const { data: stillThere } = await db
    .from('expense_voucher_approval')
    .select('decision')
    .eq('id', trailRow!.id)
    .single();
  expect(stillThere!.decision).toBe('approved');
});
