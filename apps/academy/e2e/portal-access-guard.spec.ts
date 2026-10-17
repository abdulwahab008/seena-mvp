import { test, expect, type Page } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// The parent portal belongs to guardians. Its pages choose "this guardian's children"
// with an unfiltered enrolment query and rely on row-level security to narrow it, which
// is right for a guardian and wrong for everyone else: a staff session's enrolment policy
// is campus-wide, so a nurse who typed /portal/fees used to see every child in the campus
// and a real fee balance. The portal layout now sends non-guardians home before any page
// renders.

async function signIn(page: Page, email: string, landing: RegExp) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(landing);
}

test('only a guardian can open the parent portal; staff and students are sent home', async ({ page }) => {
  test.setTimeout(150000);
  const { db, tenant, campusId, email: ownerEmail, challans } = await seedFeesTenant(1, 'portal-guard-e2e');
  const challan = challans[0]!;
  const runId = randomUUID().slice(0, 8);

  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challan.enrolment_id).single();
  const studentId = enrolment!.student_id as string;

  // A guardian, built the way guardian activation builds one: an auth user and a guardian
  // row pointing at it, no app_user row.
  const parentEmail = `parent-${runId}@portal-guard-e2e.test`;
  const { data: parentUser } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db
    .from('guardian')
    .insert({ tenant_id: tenant, name_en: 'Guard Parent', phone_e164: '+923001230999', auth_user_id: parentUser.user!.id })
    .select('id')
    .single();
  await db.from('student_guardian').insert({
    tenant_id: tenant, student_id: studentId, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true,
  });

  // A staff member with no job in fees at all: a nurse carries no permission codes.
  const nurseEmail = `nurse-${runId}@portal-guard-e2e.test`;
  const { data: nurseUser } = await db.auth.admin.createUser({ email: nurseEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: nurseUser.user!.id, tenant_id: tenant, app_role: 'nurse', full_name: 'Portal Guard Nurse' });
  await db.from('user_campus').insert({ user_id: nurseUser.user!.id, tenant_id: tenant, campus_id: campusId });

  // A student account, created directly so the test does not depend on the first-login password change.
  const studentEmail = `student-${runId}@portal-guard-e2e.test`;
  const { data: studentUser } = await db.auth.admin.createUser({ email: studentEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('student_portal_account').insert({
    tenant_id: tenant, campus_id: campusId, student_id: studentId, user_id: studentUser.user!.id, status: 'active', must_change_password: false,
  });

  // 1. A nurse is sent back to the staff dashboard from every portal page, not just the fees one.
  await signIn(page, nurseEmail, /\/dashboard/);
  for (const path of ['/portal/fees', '/portal/results', '/portal/attendance', '/portal/homework']) {
    await page.goto(path);
    await expect(page).toHaveURL(/\/dashboard$/);
    await expect(page.getByRole('heading', { name: 'Fee Dues & Billing' })).toHaveCount(0);
  }
  await page.context().clearCookies();

  // 2. The school owner is a staff session too.
  await signIn(page, ownerEmail, /\/dashboard/);
  await page.goto('/portal/fees');
  await expect(page).toHaveURL(/\/dashboard$/);
  await page.context().clearCookies();

  // 3. A student is sent to their own portal.
  await signIn(page, studentEmail, /\/student\//);
  await page.goto('/portal/fees');
  await expect(page).toHaveURL(/\/student\/timetable$/);
  await page.context().clearCookies();

  // 4. The guardian still gets the portal, with their own child and nothing else.
  await signIn(page, parentEmail, /\/portal/);
  await page.goto('/portal/fees');
  await expect(page).toHaveURL(/\/portal\/fees$/);
  await expect(page.getByRole('heading', { level: 2 })).toContainText('Fee Dues & Billing');
  // The name only shows in the switcher for two or more children; the page has a child when it is not the empty state.
  await expect(page.getByTestId('portal-fees-page')).toBeVisible();
  await expect(page.getByTestId('portal-fees-empty')).toHaveCount(0);
  await expect(page.getByTestId('fees-outstanding-balance')).toBeVisible();

  // The two portal pages that used to be checked from a staff session, now from the guardian's.
  await page.goto('/portal/circulars');
  await expect(page.locator('h2')).toContainText('Official School Circulars');
  await page.goto('/portal/calendar');
  await expect(page.locator('h2')).toContainText('Campus Events & Holidays Calendar');
});
