import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-A11: a Principal builds a Coordinator role out of the permissions they
// themselves hold, is not offered the one they do not (tenant.billing.manage),
// and cannot delete the role while somebody still holds it.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const principalEmail = `principal-${runId}@custom-role-e2e.test`;
  const holderEmail = `holder-${runId}@custom-role-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `custom-role-e2e-${runId}`,
    p_legal_name: `Custom Role E2E School ${runId}`,
    p_owner_email: principalEmail,
  });
  if (e1) throw e1;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();

  const users: Record<string, string> = {};
  for (const [email, appRole] of [
    [principalEmail, 'principal'],
    [holderEmail, 'subject_teacher'],
  ] as const) {
    const { data: created, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
    if (error || !created.user) throw error ?? new Error('user creation failed');
    users[email] = created.user.id;
    const { error: e2 } = await admin
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: appRole, full_name: email });
    if (e2) throw e2;
    const { error: e3 } = await admin
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
    if (e3) throw e3;
  }

  return { principalEmail, password, tenantId: tenantId as string, holderId: users[holderEmail]!, admin };
}

test('a principal creates a custom role, is not offered a permission they lack, and cannot delete it while held', async ({
  page,
}) => {
  const { principalEmail, password, tenantId, holderId, admin } = await seed();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(principalEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/roles');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('roles-view')).toBeVisible();
  await expect(page.getByTestId('roles-empty')).toBeVisible();

  await page.getByTestId('new-role').click();
  await expect(page.getByTestId('role-form')).toBeVisible();

  // AC1: the picker offers only what the caller holds. A Principal holds
  // student.read; they do not hold tenant.billing.manage, so it is absent.
  await expect(page.getByTestId('perm-student.read')).toBeVisible();
  await expect(page.getByTestId('perm-tenant.billing.manage')).toHaveCount(0);

  await page.getByTestId('role-name').fill('Coordinator');
  await page.getByTestId('perm-student.read').check();
  await page.getByTestId('perm-attendance.read').check();
  await page.getByTestId('save-role').click();

  await expect(page.getByTestId('role-coordinator')).toBeVisible();
  await expect(page.getByTestId('role-holders-coordinator')).toContainText('0 holder');

  // AC1 again, this time as the FR's Notes insist: the same grant attempted
  // straight at the RPC, with no picker in the way, is still refused. Signing
  // in on its own client — signInWithPassword would otherwise replace the
  // service-role token on `admin` with the principal's for every later call.
  const anon = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false },
  });
  const { data: session } = await anon.auth.signInWithPassword({ email: principalEmail, password });
  const asPrincipal = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${session.session!.access_token}` } },
  });
  const { error: escalation } = await asPrincipal.rpc('create_custom_role', {
    p_name: 'Bursar',
    p_permission_codes: ['student.read', 'tenant.billing.manage'],
  });
  expect(escalation?.message).toContain('PERMISSION_ESCALATION');

  // AC2: with a holder on it, deletion is refused and reassignment is offered.
  const { data: role } = await admin
    .from('role')
    .select('id')
    .eq('tenant_id', tenantId)
    .eq('code', 'coordinator')
    .single();
  const { error: assignError } = await admin
    .from('app_user')
    .update({ custom_role_id: role!.id })
    .eq('user_id', holderId);
  expect(assignError).toBeNull();

  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('role-holders-coordinator')).toContainText('1 holder');

  await page.getByTestId('delete-role-coordinator').click();
  await expect(page.getByText(/1 user\(s\) hold Coordinator/)).toBeVisible();

  await page.getByTestId('reassign-holders').click();
  await expect(page.getByTestId('role-holders-coordinator')).toContainText('0 holder');

  await page.getByTestId('delete-role-coordinator').click();
  await expect(page.getByTestId('roles-empty')).toBeVisible();
});
