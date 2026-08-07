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
  const ownerEmail = `owner-${runId}@parallel-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `parallel-e2e-${runId}`,
    p_legal_name: `Parallel E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const csTeacherEmail = `cs-${runId}@parallel-e2e.test`;
  const { data: csTeacherUser, error: e4 } = await admin.auth.admin.createUser({ email: csTeacherEmail, password, email_confirm: true });
  if (e4 || !csTeacherUser.user) throw e4 ?? new Error('cs teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: csTeacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'CS Teacher' });
  if (e5) throw e5;

  const bioTeacherEmail = `bio-${runId}@parallel-e2e.test`;
  const { data: bioTeacherUser, error: e6 } = await admin.auth.admin.createUser({ email: bioTeacherEmail, password, email_confirm: true });
  if (e6 || !bioTeacherUser.user) throw e6 ?? new Error('bio teacher creation failed');
  const { error: e7 } = await admin
    .from('app_user')
    .insert({ user_id: bioTeacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Bio Teacher' });
  if (e7) throw e7;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: section, error: e8 } = await admin
    .from('class_section')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, name: 'A', capacity: 30 })
    .select('id')
    .single();
  if (e8 || !section) throw e8 ?? new Error('section creation failed');

  const { data: maths, error: e9 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'MATH', name_en: 'Maths', name_ur: 'ریاضی' })
    .select('id')
    .single();
  if (e9 || !maths) throw e9 ?? new Error('maths subject creation failed');
  const { data: cs, error: e10 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'CS', name_en: 'Computer Science', name_ur: 'کمپیوٹر سائنس' })
    .select('id')
    .single();
  if (e10 || !cs) throw e10 ?? new Error('cs subject creation failed');
  const { data: bio, error: e11 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'BIO', name_en: 'Biology', name_ur: 'حیاتیات' })
    .select('id')
    .single();
  if (e11 || !bio) throw e11 ?? new Error('bio subject creation failed');

  const { error: e12 } = await admin
    .from('class_subject')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, class_level_id: classLevel!.id, subject_id: maths.id, weekly_periods: 1 });
  if (e12) throw e12;
  // CS and Biology form elective bucket 1 — a student chooses exactly one.
  const { error: e13 } = await admin.from('class_subject').insert([
    {
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      subject_id: cs.id,
      is_compulsory: false,
      elective_bucket: 1,
      choose_n: 1,
      weekly_periods: 1,
    },
    {
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      class_level_id: classLevel!.id,
      subject_id: bio.id,
      is_compulsory: false,
      elective_bucket: 1,
      choose_n: 1,
      weekly_periods: 1,
    },
  ]);
  if (e13) throw e13;

  const { error: e14 } = await admin.from('staff_teachable_subject').insert([
    { tenant_id: tenantId as string, staff_id: csTeacherUser.user.id, subject_id: cs.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
    { tenant_id: tenantId as string, staff_id: csTeacherUser.user.id, subject_id: maths.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
    { tenant_id: tenantId as string, staff_id: bioTeacherUser.user.id, subject_id: bio.id, class_level_from_id: classLevel!.id, class_level_to_id: classLevel!.id },
  ]);
  if (e14) throw e14;

  const { data: room1, error: e15 } = await admin
    .from('room')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, code: 'R1', name: 'Room 1', room_type: 'CLASSROOM', capacity: 30 })
    .select('id')
    .single();
  if (e15 || !room1) throw e15 ?? new Error('room 1 creation failed');
  const { data: room2, error: e16 } = await admin
    .from('room')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, code: 'R2', name: 'Room 2', room_type: 'CLASSROOM', capacity: 30 })
    .select('id')
    .single();
  if (e16 || !room2) throw e16 ?? new Error('room 2 creation failed');

  const { data: bellTemplate, error: e17 } = await admin
    .from('bell_template')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, shift: 'MORNING', code: 'REGULAR', name: 'Regular', is_default: true })
    .select('id')
    .single();
  if (e17 || !bellTemplate) throw e17 ?? new Error('bell template creation failed');
  const { error: e18 } = await admin.from('bell_period').insert([
    { bell_template_id: bellTemplate.id, segment_ordinal: 1, period_no: 1, kind: 'TEACHING', start_time: '08:00', end_time: '08:40' },
    { bell_template_id: bellTemplate.id, segment_ordinal: 2, period_no: 2, kind: 'TEACHING', start_time: '09:00', end_time: '09:40' },
  ]);
  if (e18) throw e18;

  const { data: version, error: e19 } = await admin
    .from('timetable_version')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, shift: 'MORNING', name: 'Draft v1', version_no: 1 })
    .select('id')
    .single();
  if (e19 || !version) throw e19 ?? new Error('version creation failed');

  return {
    ownerEmail,
    password,
    versionId: version.id as string,
    sectionId: section.id as string,
    mathsId: maths.id as string,
    csId: cs.id as string,
    bioId: bio.id as string,
    csTeacherId: csTeacherUser.user.id,
  };
}

test('an owner builds a parallel elective block, sees both members share the cell, and clearing removes both together', async ({ page }) => {
  const { ownerEmail, password, versionId, sectionId } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto(`/academic-setup/timetable?version=${versionId}&section=${sectionId}`);
  await page.waitForLoadState('networkidle');

  // A plain, ordinary period first — proves the new toggle doesn't disturb
  // the existing non-elective flow.
  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Maths (MATH)' }).click();
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Monday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('1');
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.').last()).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('MATH');
  await expect(page.getByTestId('slot-elective-toggle')).not.toBeChecked();

  // AC2: start a genuine parallel elective block — Computer Science first.
  await page.getByTestId('slot-weekday-trigger').click();
  await page.getByRole('option', { name: 'Monday', exact: true }).click();
  await page.getByTestId('slot-period-input').fill('2');
  await page.getByTestId('slot-elective-toggle').check();
  await page.getByTestId('slot-elective-bucket-input').fill('1');
  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Computer Science (CS)' }).click();
  await page.getByTestId('slot-staff-trigger').click();
  await page.getByRole('option', { name: 'CS Teacher' }).click();
  await page.getByTestId('slot-room-trigger').click();
  await page.getByRole('option', { name: 'Room 1 (R1)' }).click();
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.').last()).toBeVisible();

  let cell = page.getByTestId('grid-cell-1-2');
  await expect(cell).toContainText('CS');
  await expect(cell).toContainText('(bucket 1)');
  await expect(cell).toContainText('R1');

  // AC2/AC4: returning to that exact cell auto-joins the existing group —
  // the toggle locks on and the bucket is pre-filled and disabled, so a
  // second, independent block can never be created for the same period.
  await expect(page.getByTestId('slot-elective-toggle')).toBeChecked();
  await expect(page.getByTestId('slot-elective-toggle')).toBeDisabled();
  await expect(page.getByTestId('slot-elective-bucket-input')).toHaveValue('1');
  await expect(page.getByTestId('slot-elective-bucket-input')).toBeDisabled();

  // Biology joins as the block's second, independent member — its own
  // teacher and room, no clash with CS's.
  await page.getByTestId('slot-subject-trigger').click();
  await page.getByRole('option', { name: 'Biology (BIO)' }).click();
  await page.getByTestId('slot-staff-trigger').click();
  await page.getByRole('option', { name: 'Bio Teacher' }).click();
  await page.getByTestId('slot-room-trigger').click();
  await page.getByRole('option', { name: 'Room 2 (R2)' }).click();
  await page.getByTestId('save-slot-button').click();
  await expect(page.getByText('Slot saved.').last()).toBeVisible();

  cell = page.getByTestId('grid-cell-1-2');
  await expect(cell).toContainText('CS');
  await expect(cell).toContainText('BIO');
  await expect(cell).toContainText('R1');
  await expect(cell).toContainText('R2');

  // AC: clear_timetable_slot() removes the whole cell by weekday/period —
  // both parallel members disappear together, in one click.
  await page.getByTestId('clear-slot-1-2').click();
  await expect(page.getByText('Slot cleared.')).toBeVisible();
  await expect(page.getByTestId('grid-cell-1-2')).toContainText('Free');
  // The unrelated plain Monday-period-1 slot is untouched by the clear.
  await expect(page.getByTestId('grid-cell-1-1')).toContainText('MATH');
});

test('AC1: a direct plain write into a cell already committed to a parallel block is rejected with SECTION_CLASH', async () => {
  const { ownerEmail, password, versionId, sectionId, mathsId, csId, csTeacherId } = await seedTenant();

  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await client.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;

  const { data: groupId, error: groupError } = await client.rpc('create_timetable_parallel_group', {
    p_version_id: versionId,
    p_section_id: sectionId,
    p_weekday: 1,
    p_period_no: 2,
    p_elective_bucket: 1,
  });
  if (groupError) throw groupError;

  const { error: csError } = await client.rpc('upsert_timetable_slot', {
    p_version_id: versionId,
    p_section_id: sectionId,
    p_weekday: 1,
    p_period_no: 2,
    p_subject_id: csId,
    p_staff_id: csTeacherId,
    p_elective_bucket: 1,
    p_parallel_group_id: groupId,
  });
  if (csError) throw csError;

  // Deliberately bypassing the UI's own auto-join guard — a raw write with
  // no parallel_group_id at all against a cell that's already a committed
  // parallel block must still be rejected at the database layer.
  const { error: plainError } = await client.rpc('upsert_timetable_slot', {
    p_version_id: versionId,
    p_section_id: sectionId,
    p_weekday: 1,
    p_period_no: 2,
    p_subject_id: mathsId,
    p_staff_id: csTeacherId,
  });

  expect(plainError?.message).toContain('SECTION_CLASH');
});

test('AC3: a student picks one elective per bucket on their profile, and the choice persists', async ({ page }) => {
  const { ownerEmail, password } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  // create_student()/enrol_student() both need a real JWT — a service-role
  // seed insert can't carry the tenant claim they check, so the student is
  // admitted and enrolled through the real UI, same as every other e2e
  // spec in this codebase that needs a real enrolment.
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Elective Kid');
  await page.getByLabel('Date of birth').fill('2015-01-01');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page.getByText('Elective Kid admitted.')).toBeVisible();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();
  await page.waitForLoadState('networkidle');

  const bucket = page.getByTestId('elective-bucket-1');
  await expect(bucket).toBeVisible();
  await bucket.getByTestId('elective-bucket-1-trigger').click();
  await page.getByRole('option', { name: 'Computer Science (CS)' }).click();
  await bucket.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Elective choice saved.').last()).toBeVisible();

  // Reload — the saved choice is read back from the database, not just
  // held in local form state.
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('elective-bucket-1-trigger')).toContainText('Computer Science (CS)');

  // Switching to the other option in the same bucket updates in place —
  // a student never ends up enrolled in both.
  await page.getByTestId('elective-bucket-1-trigger').click();
  await page.getByRole('option', { name: 'Biology (BIO)' }).click();
  await page.getByTestId('elective-bucket-1').getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Elective choice saved.').last()).toBeVisible();
  await page.reload();
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('elective-bucket-1-trigger')).toContainText('Biology (BIO)');
});
