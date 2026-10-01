import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I04: a draft datesheet is invisible to parents; publishing makes version 1; a moved paper republished is
// version 2 with a revised banner and the changed row highlighted, and version 1 stays retrievable.

test('publish, revise and republish a datesheet; the parent sees the current version with a revised banner', async ({ page, browser, baseURL }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(1, 'dsver-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();

  const csIds: string[] = [];
  for (const [code, name] of [['MTH', 'Mathematics'], ['SCI', 'Science']] as const) {
    const { data: s } = await db.from('subject').insert({ tenant_id: tenant, code, name_en: name, name_ur: name }).select('id').single();
    const { data: cs, error } = await owner$.rpc('upsert_class_subject', { p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: level!.id, p_subject_id: s!.id, p_weekly_periods: 5 });
    expect(error).toBeNull();
    csIds.push(cs as string);
  }
  const { data: term } = await owner$.rpc('upsert_exam_term', { p_campus_id: campusId, p_session_id: session!.id, p_code: 'T1', p_name: 'First Term', p_sequence: 1, p_weight_pct: 100 });
  await owner$.rpc('activate_exam_terms', { p_session_id: session!.id, p_campus_id: campusId });
  const components = [{ component: 'theory', max_marks: 100, pass_marks: 33 }];
  const examSubjects: string[] = [];
  for (const cs of csIds) {
    const { data, error } = await owner$.rpc('upsert_exam_subject', { p_exam_term_id: term as string, p_class_subject_id: cs, p_components: components });
    expect(error).toBeNull();
    examSubjects.push(data as string);
  }
  const { data: ds, error: dsError } = await owner$.rpc('create_datesheet', { p_campus_id: campusId, p_exam_term_id: term as string, p_title: 'First Term datesheet' });
  expect(dsError).toBeNull();
  await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: examSubjects[0]!, p_exam_date: '2026-09-08', p_start_time: '09:00', p_end_time: '11:00' });
  await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: examSubjects[1]!, p_exam_date: '2026-09-10', p_start_time: '09:00', p_end_time: '11:00' });

  // A parent linked to the seeded child.
  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const parentEmail = `parent-${randomUUID().slice(0, 8)}@dsver-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Datesheet Parent', phone_e164: '+923001239999', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const parent = await pctx.newPage();
  await parent.goto('/login');
  await parent.waitForLoadState('networkidle');
  await parent.getByLabel('Email').fill(parentEmail);
  await parent.getByLabel('Password').fill(SEED_PASSWORD);
  await parent.getByRole('button', { name: 'Sign in' }).click();
  await parent.waitForURL(/\/portal/);

  // AC3: still a draft -> nothing listed.
  await parent.goto('/portal/datesheet');
  await expect(parent.getByTestId('portal-datesheet-empty')).toBeVisible();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  // AC1: publish -> version 1, source read-only.
  await page.goto('/exams/datesheet');
  await expect(page.getByTestId('slot-row')).toHaveCount(2);
  await page.getByTestId('publish-datesheet').click();
  await expect(page.getByTestId('datesheet-status')).toHaveText('published');
  await expect(page.getByTestId('version-row')).toHaveCount(1);
  await expect(page.getByTestId('save-slot')).toHaveCount(0);

  await parent.goto('/portal/datesheet');
  await expect(parent.getByTestId('portal-datesheet-title')).toContainText('version 1');
  await expect(parent.getByTestId('portal-datesheet-row')).toHaveCount(2);
  await expect(parent.getByTestId('datesheet-revised-banner')).toHaveCount(0);

  // AC2: move a paper by a day and republish -> version 2, version 1 retrievable.
  await page.getByTestId('reopen-datesheet').click();
  await expect(page.getByTestId('datesheet-status')).toHaveText('draft');
  const { error: moveError } = await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: examSubjects[1]!, p_exam_date: '2026-09-11', p_start_time: '09:00', p_end_time: '11:00' });
  expect(moveError).toBeNull();
  await page.reload();
  await page.getByLabel(/What changed/).fill('Science moved a day');
  await page.getByTestId('publish-datesheet').click();
  await expect(page.getByTestId('version-row')).toHaveCount(2);

  await parent.goto('/portal/datesheet');
  await expect(parent.getByTestId('portal-datesheet-title')).toContainText('version 2');
  await expect(parent.getByTestId('datesheet-revised-banner')).toContainText('Science moved a day');
  await expect(parent.locator('[data-testid="portal-datesheet-row"][data-changed="true"]')).toHaveCount(1);
  await parent.getByRole('link', { name: 'Version 1' }).click();
  await expect(parent.getByTestId('datesheet-old-version')).toBeVisible();
  await expect(parent.getByTestId('portal-datesheet-row')).toHaveCount(2);
  await pctx.close();
});
