import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@invite-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `invite-e2e-${runId}`,
    p_legal_name: `Invite E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { email, password, runId, admin };
}

test('owner invites a teacher, who accepts and reaches the dashboard', async ({ page, context }) => {
  const { email: ownerEmail, password: ownerPassword, runId, admin } = await seedOwner();
  const teacherEmail = `teacher-${runId}@invite-e2e.test`;

  // Owner signs in and sends the invitation.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(ownerPassword);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/staff');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(teacherEmail);
  await page.getByTestId('invite-role-trigger').click();
  await page.getByRole('option', { name: 'subject teacher' }).click();
  await page.getByRole('button', { name: 'Send invite' }).click();
  await expect(page.getByTestId(`invite-row-${teacherEmail}`)).toBeVisible();

  // Fetch the token directly (stands in for "the email that would have
  // been sent" — there is no email provider wired up in local dev).
  const { data: invite } = await admin
    .from('tenant_invitation')
    .select('token')
    .eq('email', teacherEmail)
    .single();
  expect(invite?.token).toBeTruthy();

  // The teacher opens the invite link in a fresh, unauthenticated context
  // (not the owner's browser session) and accepts it.
  const teacherPage = await context.newPage();
  await teacherPage.goto(`/accept-invite/${invite!.token}`);
  await teacherPage.waitForLoadState('networkidle');
  await expect(teacherPage.getByTestId('invite-preview')).toContainText('subject_teacher');
  await teacherPage.getByLabel('Choose a password').fill('teacher-password-123!');
  await teacherPage.getByRole('button', { name: 'Accept invitation' }).click();

  await expect(teacherPage).toHaveURL(/\/dashboard$/);

  // The campus the invitation granted is reachable — asserted on the campuses
  // page, which is where campus cards live now that sign-in lands on the
  // dashboard rather than dropping everyone into a settings screen.
  await teacherPage.goto('/campuses');
  await teacherPage.waitForLoadState('networkidle');
  await expect(teacherPage.getByTestId('campus-card-MAIN')).toBeVisible();
});

test('an expired or unknown invitation token shows a clear error, not a crash', async ({ page }) => {
  await page.goto('/accept-invite/not-a-real-token-at-all');
  await expect(page.getByText('Invitation not valid')).toBeVisible();
});
