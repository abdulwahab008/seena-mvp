import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@teachscope-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `teachscope-e2e-${runId}`,
    p_legal_name: `Teach Scope E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const teacherEmail = `teacher-${runId}@teachscope-e2e.test`;
  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Physics Teacher' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: class9 } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '9').single();
  const { data: class11 } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '11').single();

  const { data: section11, error: e6 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: class11!.id, name: 'A', capacity: 30 })
    .select('id')
    .single();
  if (e6) throw e6;

  const { data: physics, error: e7 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'PHY', name_en: 'Physics', name_ur: 'فزکس' })
    .select('id')
    .single();
  if (e7) throw e7;
  const { error: e8 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: class11!.id, subject_id: physics!.id, weekly_periods: 5 });
  if (e8) throw e8;

  const { data: bellTemplate, error: e9 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e9) throw e9;
  const { error: e10 } = await admin
    .from('bell_period')
    .insert({ bell_template_id: bellTemplate!.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' });
  if (e10) throw e10;

  const { data: version, error: e11 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Draft v1' })
    .select('id')
    .single();
  if (e11) throw e11;

  // The teacher is approved for Physics grade 9 only — assigning them to
  // grade 11 (section11) is deliberately out of scope for this spec.
  const { error: e12 } = await admin
    .from('staff_teachable_subject')
    .insert({ tenant_id: tenantId as string, staff_id: teacherUser.user.id, subject_id: physics!.id, class_level_from_id: class9!.id, class_level_to_id: class9!.id });
  if (e12) throw e12;

  return { ownerEmail, password, versionId: version!.id, section11Id: section11!.id, teacherName: 'Physics Teacher' };
}

test('an owner manages teachable-subject approvals and overrides a scope violation with a reason', async ({ page }) => {
  const { ownerEmail, password, versionId, section11Id, teacherName } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  // AC-adjacent: the approvals list shows the seeded grade-9-only grant.
  await page.goto('/academic-setup/teachable-subjects');
  await page.waitForLoadState('networkidle');
  await expect(page.getByText(`${teacherName} — Physics (PHY)`)).toBeVisible();
  await expect(page.getByText('Class 9 to Class 9')).toBeVisible();

  // AC #1/#2: assigning this teacher to grade 11 (out of their approved
  // range) is rejected, then succeeds once a reason is supplied.
  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${section11Id}`);
  await page.waitForLoadState('networkidle');

  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Physics (PHY)' }).click();
  await page.getByTestId('slot-staff-trigger').click();
  await page.getByRole('option', { name: teacherName }).click();
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();

  await expect(page.getByText(/Supply a reason to override/)).toBeVisible();
  await expect(page.getByTestId('slot-override-reason-input')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('Free');

  await page.getByTestId('slot-override-reason-input').fill('temporary cover until replacement joins');
  await page.getByRole('button', { name: 'Save with override' }).click();
  await expect(page.getByText('Slot saved.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('PHY');
});
