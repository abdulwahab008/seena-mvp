import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@hwload-e2e.test`;
  const teacherEmail = `teacher-${runId}@hwload-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `hwload-e2e-${runId}`,
    p_legal_name: `HW Load E2E School ${runId}`,
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
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Load Teacher' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  // Same gotcha this suite has hit before (see homework.spec.ts): without a
  // user_campus row the teacher's JWT carries an empty campus_ids claim and
  // class_section's RLS silently drops the /homework page's own join.
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
    .insert({ tenant_id: tenantId as string, code: 'MATH', name_en: 'Maths', name_ur: 'ریاضی' })
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
    effective_from: new Date(Date.now() - 60 * 86400000).toISOString().slice(0, 10),
  });
  if (e8) throw e8;

  return {
    ownerEmail,
    teacherEmail,
    password,
    tenantId: tenantId as string,
    campusId: campus!.id as string,
    sessionId: session!.id as string,
  };
}

test('a teacher publishing past the daily section cap sees a non-blocking warning, and the load calendar reflects it', async ({ page }) => {
  const { ownerEmail, teacherEmail, password, campusId, sessionId } = await seedTenant();

  // FR-H03 has no dedicated UI for arming the campus/session cap yet — the
  // owner sets it via the real RPC under their own authenticated session,
  // same "seed non-UI-exposed config through a signed-in client" convention
  // already used by section-double-booking-prevention.spec.ts.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;
  const { error: policyError } = await ownerClient.rpc('set_homework_load_policy', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_max_assignments_per_day: 2,
    p_max_minutes_per_day: null,
  });
  if (policyError) throw policyError;

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(teacherEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/homework');
  await page.waitForLoadState('networkidle');

  const today = new Date().toISOString().slice(0, 10);
  const dueDate = new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10);

  const assignments: Array<{ title: string; minutes: number }> = [
    { title: 'Load Assignment 1', minutes: 20 },
    { title: 'Load Assignment 2', minutes: 25 },
    { title: 'Load Assignment 3', minutes: 30 },
  ];
  const titles = assignments.map((a) => a.title);
  for (const { title, minutes } of assignments) {
    await page.getByLabel('Title').fill(title);
    await page.getByLabel('Assigned date').fill(today);
    await page.getByLabel('Due date').fill(dueDate);
    await page.getByLabel('Est. minutes (optional)').fill(String(minutes));
    await page.getByRole('button', { name: 'Save as draft' }).click();
    // Sonner stacks toasts rather than replacing them, so an identical
    // message from a prior loop iteration is still on screen — match the
    // newest one instead of asserting a single (now ambiguous) match.
    await expect(page.getByText('Homework saved as draft.').last()).toBeVisible();
  }

  // AC1: the first 2 (at the cap) publish clean — no warning toast.
  for (const title of titles.slice(0, 2)) {
    const row = page.getByTestId(`homework-row-${title}`);
    await row.getByRole('button', { name: 'Publish' }).click();
    await expect(page.getByText('Published.', { exact: true }).last()).toBeVisible();
    await expect(page.getByText(/already has \d+ assignment/)).not.toBeVisible();
  }

  // AC1: the 3rd, past the cap, still publishes (non-blocking) and now
  // carries the warning toast naming the prior count and prior minutes.
  const thirdRow = page.getByTestId(`homework-row-${titles[2]}`);
  await thirdRow.getByRole('button', { name: 'Publish' }).click();
  await expect(page.getByText(/already has 2 assignment\(s\) due on .* \(est\. 45 min\)/)).toBeVisible({ timeout: 10000 });
  await expect(page.getByTestId(`homework-status-${titles[2]}`)).toHaveText('published');

  // AC2: the section load calendar (14-day view, defaulted to this
  // teacher's only section) reflects all 3 published assignments on the
  // due date, with no "Publish" button left on any of the three rows.
  for (const title of titles) {
    await expect(page.getByTestId(`homework-row-${title}`).getByRole('button', { name: 'Publish' })).not.toBeVisible();
  }
  const loadRow = page.getByTestId(`load-day-${dueDate}`);
  await expect(loadRow).toContainText('3');
  await expect(loadRow).toContainText('75');
});
