import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant(sectionCount: number) {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@clash-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `clash-e2e-${runId}`,
    p_legal_name: `Clash E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const teacherEmail = `teacher-${runId}@clash-e2e.test`;
  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Mr Kamran' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const sectionIds: string[] = [];
  for (let i = 0; i < sectionCount; i++) {
    const { data: section, error: e6 } = await admin
      .from('class_section')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name: String.fromCharCode(65 + i),
        capacity: 30,
      })
      .select('id')
      .single();
    if (e6) throw e6;
    sectionIds.push(section!.id);
  }

  const { data: physics, error: e7 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e7) throw e7;
  const { error: e8 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: physics!.id, weekly_periods: 5 });
  if (e8) throw e8;

  const { data: bellTemplate, error: e9 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e9) throw e9;
  const { error: e10 } = await admin.from('bell_period').insert([
    { bell_template_id: bellTemplate!.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' },
    { bell_template_id: bellTemplate!.id, segment_ordinal: 2, period_no: 2, kind: 'TEACHING', start_time: '09:00', end_time: '09:40' },
  ]);
  if (e10) throw e10;

  const { data: version, error: e11 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Draft v1' })
    .select('id')
    .single();
  if (e11) throw e11;

  return { ownerEmail, password, tenantId: tenantId as string, campusId: campus!.id, versionId: version!.id, sectionIds, physicsId: physics!.id, teacherId: teacherUser.user.id };
}

test('an owner sees a named clash naming the section and time when double-booking a teacher', async ({ page }) => {
  const { ownerEmail, password, versionId, sectionIds } = await seedTenant(2);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionIds[0]}`);
  await page.waitForLoadState('networkidle');

  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Physics (PHY)' }).click();
  await page.getByTestId('slot-staff-trigger').click();
  await page.getByRole('option', { name: 'Mr Kamran' }).click();
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Monday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('2');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.')).toBeVisible();

  // AC: assigning the same teacher to section B at the same clock time is
  // rejected, naming section A and the clash time — not just a generic
  // "conflict" message.
  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionIds[1]}`);
  await page.waitForLoadState('networkidle');

  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Physics (PHY)' }).click();
  await page.getByTestId('slot-staff-trigger').click();
  await page.getByRole('option', { name: 'Mr Kamran' }).click();
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Monday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('2');
  await page.getByTestId('save-slot-button').click();

  await expect(page.getByText('This teacher already has a clash — section A at 09:00-09:40.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-2')).toContainText('Free');
});

test('20 concurrent writes for the same teacher, weekday and period — exactly 1 commits', async ({}) => {
  const { ownerEmail, password, versionId, sectionIds, physicsId, teacherId } = await seedTenant(20);

  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await client.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;

  // 20 genuinely concurrent RPC calls — real parallel Postgres backends,
  // not sequential UI clicks — each targeting a different section but the
  // exact same teacher/weekday/period, so only the clash check (not the
  // (version,section,weekday,period) uniqueness constraint) can be what
  // decides the outcome.
  const results = await Promise.allSettled(
    sectionIds.map((sectionId) =>
      client.rpc('upsert_timetable_slot', {
        p_version_id: versionId,
        p_section_id: sectionId,
        p_weekday: 1,
        p_period_no: 2,
        p_subject_id: physicsId,
        p_staff_id: teacherId,
      }),
    ),
  );

  const succeeded = results.filter((r) => r.status === 'fulfilled' && !r.value.error);
  const clashed = results.filter((r) => r.status === 'fulfilled' && r.value.error?.message.includes('TEACHER_CLASH'));

  expect(succeeded).toHaveLength(1);
  expect(clashed).toHaveLength(19);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { count } = await admin
    .from('timetable_slot')
    .select('id', { count: 'exact', head: true })
    .eq('timetable_version_id', versionId)
    .eq('weekday', 1)
    .eq('staff_id', teacherId);
  expect(count).toBe(1);
});
