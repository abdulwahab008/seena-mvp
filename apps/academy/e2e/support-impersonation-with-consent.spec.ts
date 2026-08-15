import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A16: an Owner consents, a support engineer acts as one of their staff,
// the whole product says so, money cannot be moved from inside the session,
// and the Owner can cut it off to the second.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

/** A client carrying one user's own JWT, for asserting a refusal is server-side. */
async function asUser(email: string) {
  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data, error } = await anon.auth.signInWithPassword({ email, password: PASSWORD });
  if (error) throw error;
  return createClient(SUPABASE_URL, ANON_KEY, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${data.session!.access_token}` } },
  });
}

async function seed() {
  const db = admin();
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@impersonation-e2e.test`;
  const engineerEmail = `support-${runId}@impersonation-e2e.test`;
  const targetEmail = `accountant-${runId}@impersonation-e2e.test`;

  const { data: tenantId, error: e1 } = await db.rpc('provision_tenant', {
    p_slug: `impersonation-e2e-${runId}`,
    p_legal_name: `Impersonation E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenantId as string).single();

  const makeUser = async (email: string, role: 'owner' | 'super_admin' | 'accountant', name: string) => {
    const { data: user, error } = await db.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (error || !user.user) throw error ?? new Error(`${role} creation failed`);
    const { error: eu } = await db
      .from('app_user')
      .insert({ user_id: user.user.id, tenant_id: tenantId as string, app_role: role, full_name: name });
    if (eu) throw eu;
    const { error: ec } = await db
      .from('user_campus')
      .insert({ tenant_id: tenantId as string, user_id: user.user.id, campus_id: campus!.id });
    if (ec) throw ec;
    return user.user.id;
  };

  // The two-person control is structural: the Owner who grants consent is
  // never the engineer who uses it (chk_impersonation_two_person).
  const ownerId = await makeUser(ownerEmail, 'owner', 'E2E Owner');
  const engineerId = await makeUser(engineerEmail, 'super_admin', 'E2E Support Engineer');
  const targetId = await makeUser(targetEmail, 'accountant', 'E2E Accountant');

  return { db, tenantId: tenantId as string, ownerEmail, engineerEmail, targetEmail, ownerId, engineerId, targetId };
}

async function signIn(page: Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

async function signOut(page: Page) {
  await page.getByTestId('user-menu-trigger').click();
  await page.getByTestId('sign-out').click();
  await expect(page).toHaveURL(/\/login\?signed_out=1$/);
}

test('consent, session, banner, blocked write, and a mid-session withdrawal that refuses the next request', async ({
  page,
}) => {
  const { db, tenantId, ownerEmail, engineerEmail, targetId } = await seed();

  // ── AC1: the Owner grants, nobody else ───────────────────────────────
  await signIn(page, ownerEmail);
  await page.goto('/impersonation');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('impersonation-view')).toBeVisible();

  await page.getByTestId('consent-target').click();
  await page.getByRole('option', { name: 'E2E Accountant (accountant)' }).click();
  await page.getByTestId('consent-hours').fill('2');
  await page.getByTestId('grant-consent').click();
  await expect(page.getByText('Support access granted.')).toBeVisible();

  const { data: consent } = await db
    .from('impersonation_consent')
    .select('id, scope, target_user_id, revoked_at')
    .eq('tenant_id', tenantId)
    .single();
  expect(consent!.scope).toBe('user');
  expect(consent!.target_user_id).toBe(targetId);
  await expect(page.getByTestId(`consent-status-${consent!.id}`)).toHaveText('Live');

  await signOut(page);

  // ── AC2: the engineer opens a session against that consent ───────────
  await signIn(page, engineerEmail);
  await page.goto('/impersonation');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('impersonation-target').click();
  await page.getByRole('option', { name: 'E2E Accountant (accountant)' }).click();
  await page.getByTestId('impersonation-minutes').fill('30');
  await page.getByTestId('start-impersonation').click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // The banner is the requirement: it must be impossible to forget.
  await expect(page.getByTestId('impersonation-banner')).toBeVisible();
  await expect(page.getByTestId('impersonation-banner-target')).toHaveText('E2E Accountant');
  await expect(page.getByTestId('impersonation-remaining')).toHaveText(/ends in \d\d:\d\d/);

  const { data: session } = await db
    .from('impersonation_session')
    .select('id, support_user_id, target_user_id, ended_at, blocked_write_count, read_count')
    .eq('tenant_id', tenantId)
    .single();
  expect(session!.target_user_id).toBe(targetId);
  expect(session!.ended_at).toBeNull();

  // AC5: sub is never rewritten, so the audit row for the session's own
  // creation is attributed to the ENGINEER, not to the accountant.
  const { data: startAudit } = await db
    .from('audit_log')
    .select('actor_user_id')
    .eq('tenant_id', tenantId)
    .eq('table_name', 'impersonation_session')
    .eq('row_id', session!.id)
    .limit(1)
    .single();
  expect(startAudit!.actor_user_id).toBe(session!.support_user_id);

  // ── The banner is on every page of the shell, not just the one ───────
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('impersonation-banner')).toBeVisible();

  // ── AC3: a money write is refused, and the refusal is recorded ───────
  await page.goto('/expenses/vouchers');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('voucher-head-trigger').click();
  await page.getByTestId('voucher-head-option-UTILITIES').click();
  await page.getByTestId('voucher-payee-input').fill('K-Electric');
  await page.getByTestId('voucher-amount-input').fill('1000');
  await page.getByTestId('voucher-date-input').fill(new Date().toISOString().slice(0, 10));
  await page.getByTestId('voucher-submit-button').click();
  await expect(page.getByText(/Blocked: financial and result-publishing changes/)).toBeVisible();

  const { count: vouchers } = await db
    .from('expense_voucher')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(vouchers).toBe(0);

  // The block itself is a BEFORE trigger and takes its own transaction with
  // it; this security_event exists only because the console's error path
  // called record_impersonation_block() in a second one.
  const { data: blockEvent } = await db
    .from('security_event')
    .select('severity, detail')
    .eq('tenant_id', tenantId)
    .eq('event_type', 'impersonation_write_blocked')
    .single();
  expect(blockEvent!.severity).toBe('alert');
  expect((blockEvent!.detail as { blocked_table: string }).blocked_table).toBe('expense_voucher');

  const { data: counted } = await db
    .from('impersonation_session')
    .select('blocked_write_count, read_count')
    .eq('id', session!.id)
    .single();
  expect(counted!.blocked_write_count).toBe(1);
  // AC6's read count, fed by impersonation_note_reads() once per page view.
  expect(counted!.read_count).toBeGreaterThan(0);

  // ── AC4: the Owner withdraws mid-session; the next request is refused ─
  const owner = await asUser(ownerEmail);
  const { data: ended, error: revokeError } = await owner.rpc('revoke_impersonation_consent', {
    p_consent_id: consent!.id,
  });
  expect(revokeError).toBeNull();
  expect(ended).toBe(1);

  await page.goto('/students');
  await expect(page.getByTestId('impersonation-ended')).toBeVisible();
  await expect(page.getByTestId('impersonation-banner')).toHaveCount(0);

  const { data: closed } = await db
    .from('impersonation_session')
    .select('ended_at, end_reason')
    .eq('id', session!.id)
    .single();
  expect(closed!.ended_at).not.toBeNull();
  expect(closed!.end_reason).toBe('consent_revoked');

  // ── The way back to being yourself ───────────────────────────────────
  await page.getByTestId('impersonation-return-to-self').click();
  await expect(page).toHaveURL(/\/dashboard$/);
  await expect(page.getByTestId('impersonation-banner')).toHaveCount(0);

  // AC6: the Owner's log tells them exactly what happened.
  await page.goto('/impersonation');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`session-status-${session!.id}`)).toHaveText('Consent withdrawn');
  await expect(page.getByTestId(`session-blocked-${session!.id}`)).toHaveText('1');
});

test('without consent there is nothing to use, and an Owner is never a target', async ({ page }) => {
  const { ownerEmail, engineerEmail, ownerId } = await seed();

  await signIn(page, engineerEmail);
  await page.goto('/impersonation');
  await page.waitForLoadState('networkidle');

  // chk_impersonation_role_ceiling, mirrored in the picker: the Owner is the
  // consent granter, so an engineer who could act as one could authorise
  // themselves.
  await page.getByTestId('impersonation-target').click();
  await expect(page.getByRole('option', { name: /E2E Owner/ })).toHaveCount(0);
  await expect(page.getByRole('option', { name: /E2E Support Engineer/ })).toHaveCount(0);
  await page.getByRole('option', { name: 'E2E Accountant (accountant)' }).click();
  await page.getByTestId('start-impersonation').click();
  await expect(page.getByText(/has not granted support access/)).toBeVisible();
  await expect(page.getByTestId('impersonation-banner')).toHaveCount(0);

  // Hiding the option is not the control — the RPC refuses the Owner outright.
  const engineer = await asUser(engineerEmail);
  const { error } = await engineer.rpc('start_impersonation', { p_target_user_id: ownerId, p_minutes: 30 });
  expect(error?.message).toContain('IMPERSONATION_ROLE_FORBIDDEN');

  // And consent is the Owner's alone to give.
  const support = await asUser(engineerEmail);
  const { error: selfGrant } = await support.rpc('grant_impersonation_consent', { p_hours: 24 });
  expect(selfGrant?.message).toContain('FORBIDDEN');

  const owner = await asUser(ownerEmail);
  const { error: ownerStart } = await owner.rpc('start_impersonation', { p_target_user_id: ownerId, p_minutes: 30 });
  expect(ownerStart?.message).toContain('FORBIDDEN');
});
