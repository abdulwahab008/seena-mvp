import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

// The applied-for date is computed from today, never a literal: this spec
// has to keep meaning the same thing next week and next year. It is also
// the key in three data-testids (leave-app-row-*, leave-app-status-*,
// approval-row-*), all of which the app builds from
// leave_application.from_date — so they are interpolated from this same
// value rather than spelled out, and cannot drift apart from it again.
//
// The next Monday, strictly in the future: a leave application is a
// request about a day that has not happened yet, and approving it writes
// staff_attendance rows for that day. Monday is unambiguously a full
// working day (FR-F02 shortens Friday; Sunday is the weekly off day), so
// nothing about the calendar can change what the 0.5-day half-day hold or
// the approval is expected to do.
function nextMonday(): string {
  const now = new Date();
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  d.setUTCDate(d.getUTCDate() + ((8 - d.getUTCDay()) % 7 || 7));
  return d.toISOString().slice(0, 10);
}

const LEAVE_DATE = nextMonday();

async function seedOwnerWithTeacherOnLeave() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@leave-e2e.test`;
  const teacherEmail = `teacher-${runId}@leave-e2e.test`;
  const password = 'e2e-test-password-123!';
  const teacherName = 'Ayesha Malik';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `leave-e2e-${runId}`,
    p_legal_name: `Leave E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: campus, error: eCampus } = await admin
    .from('campus')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .single();
  if (eCampus || !campus) throw eCampus ?? new Error('campus not seeded');

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: teacherName });
  if (e5) throw e5;

  // FR-A12's campus gate: a campus-scoped role with zero active
  // user_campus rows never reaches any /(app) page at all — the layout
  // replaces the whole shell with the "No campus assigned" screen.
  const { error: e5b } = await admin
    .from('user_campus')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, campus_id: campus.id });
  if (e5b) throw e5b;

  // Seeded directly (not via create_staff/create_leave_type/fn_grant_leave_balance's
  // RPCs), the same way other e2e specs seed prerequisite data: those
  // functions' own FORBIDDEN checks read JWT claims a service-role call
  // never carries. staff.user_id is set immediately here rather than via a
  // separate link_staff_user_account call — that RPC's own job (linking a
  // pre-existing staff record to a login created later) is already fully
  // covered by pgTAP, and has no dedicated UI screen for this spec to drive.
  const { data: staff, error: e6 } = await admin
    .from('staff')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus.id,
      user_id: teacherUser.user.id,
      employee_code: 'T-0001',
      cnic: '42101-1234004-1',
      gender: 'female',
      full_name: teacherName,
    })
    .select('id')
    .single();
  if (e6 || !staff) throw e6 ?? new Error('staff creation failed');

  const { data: leaveType, error: e7 } = await admin
    .from('leave_type')
    .insert({ tenant_id: tenantId as string, code: 'CASUAL', name_en: 'Casual Leave', entitlement_days: 10 })
    .select('id')
    .single();
  if (e7 || !leaveType) throw e7 ?? new Error('leave type creation failed');

  const { error: e8 } = await admin
    .from('leave_ledger')
    .insert({ tenant_id: tenantId as string, staff_id: staff.id, leave_type_id: leaveType.id, entry_type: 'grant', days: 10 });
  if (e8) throw e8;

  return { ownerEmail, teacherEmail, password, teacherName };
}

test('a teacher applies for half-day leave and the owner approves it', async ({ page, browser }) => {
  const { ownerEmail, teacherEmail, password, teacherName } = await seedOwnerWithTeacherOnLeave();

  // Teacher signs in, sees her balance, and applies for a half day.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(teacherEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/leave');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('leave-balance-CASUAL')).toContainText('10.00d left');

  await page.getByTestId('leave-type-trigger').click();
  await page.getByRole('option', { name: 'Casual Leave' }).click();
  await page.getByLabel('Half day').check();
  await page.getByLabel('From').fill(LEAVE_DATE);
  await page.getByRole('button', { name: 'Apply for leave' }).click();

  await expect(page.getByText('Leave application submitted.')).toBeVisible();
  // apply_for_leave() holds the days immediately, before any decision — the
  // balance must reflect that hold right away, not only after approval.
  await expect(page.getByTestId('leave-balance-CASUAL')).toContainText('9.50d left');
  const teacherRow = page.getByTestId(`leave-app-row-CASUAL-${LEAVE_DATE}`);
  await expect(teacherRow).toBeVisible();
  await expect(page.getByTestId(`leave-app-status-CASUAL-${LEAVE_DATE}`)).toHaveText('pending');

  // Owner signs in, in a genuinely separate browser context (not just a new
  // tab — a new page in the teacher's own context would share her session
  // cookies and log her out), and approves it. No approval chain is
  // configured for this campus/leave type, so this exercises the
  // fn_decide_leave_application single-step fallback.
  const ownerContext = await browser.newContext();
  const ownerPage = await ownerContext.newPage();
  await ownerPage.goto('/login');
  await ownerPage.waitForLoadState('networkidle');
  await ownerPage.getByLabel('Email').fill(ownerEmail);
  await ownerPage.getByLabel('Password').fill(password);
  await ownerPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(ownerPage).toHaveURL(/\/dashboard$/);

  await ownerPage.goto('/leave');
  await ownerPage.waitForLoadState('networkidle');
  const queueRow = ownerPage.getByTestId(`approval-row-${teacherName}-${LEAVE_DATE}`);
  await expect(queueRow).toBeVisible();
  await expect(queueRow).toContainText('Casual Leave');
  await queueRow.getByRole('button', { name: 'Approve' }).click();

  await expect(ownerPage.getByText('Application approved.')).toBeVisible();
  await expect(ownerPage.getByTestId(`approval-row-${teacherName}-${LEAVE_DATE}`)).not.toBeVisible();

  // Back on the teacher's side: reload to pick up the owner's decision.
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId(`leave-app-status-CASUAL-${LEAVE_DATE}`)).toHaveText('approved');
  // hold_release + consumption net to the same balance as the original
  // hold — approval must not double-deduct or silently refund the days.
  await expect(page.getByTestId('leave-balance-CASUAL')).toContainText('9.50d left');
});
