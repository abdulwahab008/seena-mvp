import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H05: a parent submits notebook photos late, replaces them, and the teacher sees the final version.

const jpeg = (size: number) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(size, 7)]);

test('a student submission is late-flagged, replaceable, and visible to the teacher only when complete', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, owner$, email, tenant, campusId, challans } = await seedFeesTenant(1, 'hwsub-e2e');
  const enrolmentId = challans[0]!.enrolment_id;
  const { data: enrol } = await db.from('enrolment').select('student_id, section_id, session_id').eq('id', enrolmentId).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'SCI', name_en: 'Science', name_ur: 'سائنس' }).select('id').single();
  const { data: auth } = await owner$.auth.getUser();
  const day = (n: number) => new Date(Date.now() + n * 86400000).toISOString().slice(0, 10);
  const { data: hw } = await db
    .from('homework')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: enrol!.session_id, section_id: enrol!.section_id, subject_id: subject!.id, teacher_id: auth.user!.id, title: 'Notebook pages', assigned_date: day(-5), due_date: day(-2), status: 'published', published_at: new Date().toISOString() })
    .select('id')
    .single();

  const parentEmail = `parent-${randomUUID().slice(0, 8)}@hwsub-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Sub Parent', phone_e164: '+923001237777', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrol!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(parentEmail);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);
  await page.goto('/portal/homework');
  await page.getByTestId('homework-submit-Notebook pages').click();

  await page.getByLabel(/Photos or PDFs/).setInputFiles({ name: 'notes.jpg', mimeType: 'image/jpeg', buffer: Buffer.concat([Buffer.from([0x4d, 0x5a, 0x90, 0x00]), Buffer.alloc(500, 1)]) });
  await page.getByTestId('submit-work').click();
  await expect(page.getByTestId('submit-error')).toContainText('only PDF, JPEG, PNG or WebP');

  await page.getByLabel(/Your answer/).fill('Pages 12 to 14');
  await page.getByLabel(/Photos or PDFs/).setInputFiles({ name: 'notes.jpg', mimeType: 'image/jpeg', buffer: jpeg(3000) });
  await page.getByTestId('submit-work').click();
  await expect(page.getByTestId('submit-done')).toContainText('Submitted as version 1 — late by');
  await expect(page.getByTestId('current-submission')).toContainText('Pages 12 to 14');
  await expect(page.getByTestId('current-submission')).toContainText('notes.jpg');

  await page.getByLabel(/Your answer/).fill('Redone neatly');
  await page.getByTestId('submit-work').click();
  await expect(page.getByTestId('submit-done')).toContainText('version 2');
  await expect(page.getByTestId('submission-history')).toContainText('Version 1');

  const teacher = await browser.newContext({ baseURL: baseURL ?? undefined });
  const tp = await teacher.newPage();
  await tp.goto('/login');
  await tp.waitForLoadState('networkidle');
  await tp.getByLabel('Email').fill(email);
  await tp.getByLabel('Password').fill(SEED_PASSWORD);
  await tp.getByRole('button', { name: 'Sign in' }).click();
  await expect(tp).toHaveURL(/\/dashboard$/);
  await tp.goto('/homework');
  await expect(tp.getByTestId('homework-submission')).toHaveCount(1);
  await expect(tp.getByTestId('homework-submission')).toContainText('late by');
  await expect(tp.getByTestId('homework-submission')).toContainText('Redone neatly');
  await teacher.close();
  expect(hw!.id).toBeTruthy();
});
