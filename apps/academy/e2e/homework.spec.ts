import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@homework-e2e.test`;
  const teacherEmail = `teacher-${runId}@homework-e2e.test`;
  const guardianEmail = `guardian-${runId}@homework-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `homework-e2e-${runId}`,
    p_legal_name: `Homework E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

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
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Chemistry Teacher' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  // Without this, the teacher's own JWT carries an empty campus_ids claim,
  // and class_section's RLS (campus-scoped, no staff_id escape hatch the
  // way section_subject_teacher's own policy has) would silently drop the
  // embedded class_section join on every section_subject_teacher row the
  // /homework page reads — the exact bug this comment is here to prevent
  // reintroducing.
  const { error: e3b } = await admin
    .from('user_campus')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e3b) throw e3b;
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  const { data: section, error: e6 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id')
    .single();
  if (e6) throw e6;

  const { data: subject, error: e7 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'CHEM', name_en: 'Chemistry', name_ur: 'کیمسٹری' })
    .select('id')
    .single();
  if (e7) throw e7;

  const { error: e8 } = await admin.from('section_subject_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    subject_id: subject!.id,
    staff_id: teacherUser.user.id,
    role: 'primary',
    // 60 days back — safely before the "overdue" homework item's own
    // assigned_date below (20 days back), or create_homework()'s validity
    // @> p_assigned_date check would reject it as FORBIDDEN.
    effective_from: new Date(Date.now() - 60 * 86400000).toISOString().slice(0, 10),
  });
  if (e8) throw e8;

  // Guardian: given both an email/password (for this e2e's own sign-in
  // convenience via the ordinary password form) and a phone their real
  // guardian record carries. FR-C11's own e2e spec already proves the real
  // WhatsApp-link + OTP activation path in depth — this spec is testing
  // the portal feed page itself, not re-proving activation. The phone is
  // randomised per run (auth.users.phone is globally unique and outlives
  // this file's own db reset between local runs).
  const guardianPhone = '923' + String(Math.floor(100000000 + Math.random() * 899999999));
  const { data: guardianUser, error: e9 } = await admin.auth.admin.createUser({
    email: guardianEmail,
    password,
    phone: guardianPhone,
    email_confirm: true,
    phone_confirm: true,
  });
  if (e9 || !guardianUser.user) throw e9 ?? new Error('guardian creation failed');

  return {
    ownerEmail,
    teacherEmail,
    guardianEmail,
    password,
    tenantId: tenantId as string,
    guardianAuthUserId: guardianUser.user.id,
    guardianPhone,
  };
}

test('a teacher publishes homework and a parent sees it live in the portal feed, grouped by overdue vs pending', async ({ page, browser }) => {
  const { ownerEmail, teacherEmail, guardianEmail, password, tenantId, guardianAuthUserId, guardianPhone } = await seedTenant();
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

  // Admit and enrol through the real UI as the owner — enrolment's own
  // AFTER INSERT trigger needs a JWT, the established gotcha this whole
  // suite works around the same way.
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Homework E2E Kid');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Homework E2E Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  const studentId = page.url().split('/students/')[1];
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  const { data: guardian, error: eg } = await admin
    .from('guardian')
    .insert({ tenant_id: tenantId, name_en: 'Homework E2E Guardian', phone_e164: `+${guardianPhone}`, auth_user_id: guardianAuthUserId })
    .select('id')
    .single();
  if (eg) throw eg;
  const { error: el } = await admin
    .from('student_guardian')
    .insert({ tenant_id: tenantId, student_id: studentId, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });
  if (el) throw el;

  // Teacher, in a separate browser context, publishes an overdue item and
  // a pending one straight away.
  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/dashboard$/);

  await teacherPage.goto('/homework');
  await teacherPage.waitForLoadState('networkidle');

  const today = new Date().toISOString().slice(0, 10);
  const pastDue = new Date(Date.now() - 10 * 86400000).toISOString().slice(0, 10);
  const pastAssigned = new Date(Date.now() - 20 * 86400000).toISOString().slice(0, 10);
  const futureDue = new Date(Date.now() + 5 * 86400000).toISOString().slice(0, 10);

  // Overdue item, published immediately.
  await teacherPage.getByLabel('Title').fill('Overdue lab report');
  await teacherPage.getByLabel('Assigned date').fill(pastAssigned);
  await teacherPage.getByLabel('Due date').fill(pastDue);
  await teacherPage.getByLabel('Publish now').check();
  await teacherPage.getByRole('button', { name: 'Publish homework' }).click();
  // Sonner stacks toasts, so wait for the new row (rendered after the form reset) rather
  // than a toast an earlier step may have left on screen.
  await expect(teacherPage.getByText('Overdue lab report (Chemistry)')).toBeVisible();

  // Pending item, published immediately too.
  await teacherPage.getByLabel('Title').fill('Chapter 3 exercises');
  await teacherPage.getByLabel('Assigned date').fill(today);
  await teacherPage.getByLabel('Due date').fill(futureDue);
  await teacherPage.getByLabel('Publish now').check();
  await teacherPage.getByRole('button', { name: 'Publish homework' }).click();
  await expect(teacherPage.getByText('Chapter 3 exercises (Chemistry)')).toBeVisible();

  // A still-draft item — must never reach the parent feed.
  await teacherPage.getByLabel('Title').fill('Not ready yet');
  await teacherPage.getByLabel('Assigned date').fill(today);
  await teacherPage.getByLabel('Due date').fill(futureDue);
  await teacherPage.getByRole('button', { name: 'Save as draft' }).click();
  await expect(teacherPage.getByText('Homework saved as draft.').last()).toBeVisible();
  await expect(teacherPage.getByText('Not ready yet (Chemistry)')).toBeVisible();

  // Guardian, in a third context, opens the portal feed.
  const guardianContext = await browser.newContext();
  const guardianPage = await guardianContext.newPage();
  await guardianPage.goto('/login');
  await guardianPage.waitForLoadState('networkidle');
  await guardianPage.getByLabel('Email').fill(guardianEmail);
  await guardianPage.getByLabel('Password').fill(password);
  await guardianPage.getByRole('button', { name: 'Sign in' }).click();
  // Sign-in has no role-specific destination, so a parent is aimed at the
  // staff dashboard like anyone else; (app)/layout.tsx recognises a session
  // with no app_user row but a linked guardian row and forwards it to the
  // portal rather than to /no-school.
  await expect(guardianPage).toHaveURL(/\/portal\/homework$/);

  await guardianPage.goto('/portal/homework');
  await guardianPage.waitForLoadState('networkidle');

  await expect(guardianPage.getByTestId('homework-feed-Overdue lab report')).toBeVisible();
  await expect(guardianPage.getByTestId('homework-feed-Chapter 3 exercises')).toBeVisible();
  await expect(guardianPage.getByTestId('homework-feed-Not ready yet')).not.toBeVisible();

  // AC: overdue sits in its own group above pending.
  const overdueHeading = guardianPage.getByRole('heading', { name: 'Overdue' });
  const pendingHeading = guardianPage.getByRole('heading', { name: 'Pending' });
  const overdueBox = await overdueHeading.boundingBox();
  const pendingBox = await pendingHeading.boundingBox();
  expect(overdueBox!.y).toBeLessThan(pendingBox!.y);

  // AC: realtime delivers a newly-published assignment without a reload —
  // wait for the channel to actually be joined first, so the publish
  // below can't race ahead of the subscription.
  await expect(guardianPage.getByTestId('homework-realtime-status')).toHaveAttribute('data-status', 'SUBSCRIBED');
  await teacherPage.getByRole('button', { name: 'Publish' }).click();
  await expect(teacherPage.getByText('Published.', { exact: true })).toBeVisible();
  await expect(guardianPage.getByTestId('homework-feed-Not ready yet')).toBeVisible({ timeout: 10000 });
});
