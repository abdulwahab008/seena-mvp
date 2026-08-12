import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerAndClassTeacher() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@offline-sync-e2e.test`;
  const teacherEmail = `teacher-${runId}@offline-sync-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `offline-sync-e2e-${runId}`,
    p_legal_name: `Offline Sync E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

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
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'class_teacher', full_name: 'Class Teacher' });
  if (e5) throw e5;
  const { error: e5b } = await admin
    .from('user_campus')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e5b) throw e5b;

  const { data: section, error: e6 } = await admin
    .from('class_section')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      name: 'A',
      capacity: 10,
    })
    .select('id')
    .single();
  if (e6) throw e6;

  const { error: e7 } = await admin.from('section_class_teacher').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    section_id: section!.id,
    staff_id: teacherUser.user.id,
    effective_from: new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10),
  });
  if (e7) throw e7;

  const { error: e8 } = await admin.from('attendance_policy').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    start_time: '08:00',
    late_threshold_minutes: 15,
    lock_window_hours: 24,
  });
  if (e8) throw e8;

  return { ownerEmail, teacherEmail, password, sectionId: section!.id };
}

async function admitAndEnrol(page: import('@playwright/test').Page, name: string) {
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill(name);
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText(`${name} admitted.`)).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();
}

// AC1 + AC2 + AC3: the whole user story, end to end — mark the register
// with no signal at all, watch it land on the device, then reconnect and
// watch it upload itself with the device capture time intact.
test('a register marked with the network down is saved on device and uploads on reconnect', async ({ page, browser }) => {
  test.setTimeout(120_000);
  const { ownerEmail, teacherEmail, password, sectionId } = await seedOwnerAndClassTeacher();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  for (const name of ['Offline Kid One', 'Offline Kid Two']) {
    await admitAndEnrol(page, name);
  }

  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/campuses$/);

  await teacherPage.goto('/attendance/register');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.locator('[data-testid^="register-row-"]')).toHaveCount(2);

  // The teacher walks into the dead-zone classroom.
  await teacherContext.setOffline(true);
  const capturedAtMs = Date.now();

  // present -> absent on the first student, then submit with no network.
  await teacherPage.getByTestId('register-status-tap').first().click();
  await expect(teacherPage.getByTestId('register-status-tap').first()).toHaveText('absent');
  await teacherPage.getByTestId('register-save').click();

  // AC1: the message, and a queue depth of exactly 1.
  await expect(teacherPage.getByTestId('offline-queue-banner')).toContainText('Saved on device — will upload when online');
  await expect(teacherPage.getByTestId('offline-queue-depth')).toHaveText('1');

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: nothingYet } = await admin.from('attendance_day').select('id').eq('section_id', sectionId);
  expect(nothingYet).toHaveLength(0);

  // ...and back to the staff room.
  await teacherContext.setOffline(false);

  await expect(teacherPage.getByTestId('offline-queue-banner')).toBeHidden({ timeout: 30_000 });

  await expect
    .poll(
      async () => {
        const { data } = await admin.from('attendance_day').select('id').eq('section_id', sectionId);
        return data?.length ?? 0;
      },
      { timeout: 30_000 }
    )
    .toBe(2);

  const { data: rows } = await admin
    .from('attendance_day')
    .select('status, source, marked_at, synced_at')
    .eq('section_id', sectionId)
    .order('status');
  expect(rows?.map((r) => r.status).sort()).toEqual(['absent', 'present']);

  // AC3: written with the device capture time, the later sync time, and
  // the provenance that says it came through the queue.
  for (const row of rows ?? []) {
    expect(row.source).toBe('offline_sync');
    expect(new Date(row.marked_at!).getTime()).toBeLessThanOrEqual(new Date(row.synced_at!).getTime());
    expect(Math.abs(new Date(row.marked_at!).getTime() - capturedAtMs)).toBeLessThan(60_000);
  }

  // AC2: exactly one ledger row, and it is the applied one.
  const { data: log } = await admin.from('attendance_sync_log').select('result, idempotency_key').eq('section_id', sectionId);
  expect(log).toHaveLength(1);
  expect(log?.[0]?.result).toBe('applied');

  await teacherContext.close();
});

// AC4: the date is locked between capture and sync, so the register is
// refused and turned into correction requests rather than vanishing.
test('a register captured offline for a date locked before the sync becomes correction requests', async ({ page, browser }) => {
  test.setTimeout(120_000);
  const { ownerEmail, teacherEmail, password, sectionId } = await seedOwnerAndClassTeacher();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);
  await admitAndEnrol(page, 'Locked Out Kid');

  const teacherContext = await browser.newContext();
  const teacherPage = await teacherContext.newPage();
  await teacherPage.goto('/login');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByLabel('Email').fill(teacherEmail);
  await teacherPage.getByLabel('Password').fill(password);
  await teacherPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(teacherPage).toHaveURL(/\/campuses$/);

  await teacherPage.goto('/attendance/register');
  await teacherPage.waitForLoadState('networkidle');
  await teacherPage.getByTestId('register-load').click();
  await expect(teacherPage.locator('[data-testid^="register-row-"]')).toHaveCount(1);

  await teacherContext.setOffline(true);
  await teacherPage.getByTestId('register-status-tap').first().click();
  await teacherPage.getByTestId('register-save').click();
  await expect(teacherPage.getByTestId('offline-queue-depth')).toHaveText('1');

  // While the device is still offline, the Principal locks that date.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: section } = await admin.from('class_section').select('tenant_id, campus_id').eq('id', sectionId).single();
  const { error: lockError } = await admin.from('attendance_lock').insert({
    tenant_id: section!.tenant_id,
    campus_id: section!.campus_id,
    section_id: sectionId,
    attendance_date: new Date().toISOString().slice(0, 10),
    locked_by: 'manual',
  });
  if (lockError) throw lockError;

  await teacherContext.setOffline(false);

  await expect(teacherPage.getByText('That date was locked before your register uploaded')).toBeVisible({ timeout: 30_000 });
  await expect(teacherPage.getByTestId('offline-queue-banner')).toBeHidden();

  const { data: written } = await admin.from('attendance_day').select('id').eq('section_id', sectionId);
  expect(written).toHaveLength(0);

  const { data: corrections } = await admin
    .from('attendance_correction_request')
    .select('status, new_status, reason')
    .eq('campus_id', section!.campus_id);
  expect(corrections).toHaveLength(1);
  expect(corrections?.[0]?.status).toBe('pending');
  expect(corrections?.[0]?.new_status).toBe('absent');
  expect(corrections?.[0]?.reason).toContain('Captured offline at');

  const { data: log } = await admin.from('attendance_sync_log').select('result, error_text').eq('section_id', sectionId);
  expect(log).toHaveLength(1);
  expect(log?.[0]?.result).toBe('rejected_locked');
  expect(log?.[0]?.error_text).toBe('attendance_locked');

  await teacherContext.close();
});
