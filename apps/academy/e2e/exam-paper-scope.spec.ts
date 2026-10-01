import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { DevPaperGenerator, paperPayloadSchema } from '../lib/exam-papers/generator';

// FR-H09: an Exam Controller scopes a paper to taught chapters; an untaught chapter is refused until explicitly overridden.

test('an untaught chapter is refused, taught chapters generate a paper with per-question provenance, and the override is recorded', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(0, 'paper-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { error: syllabusError } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: subject!.id, p_board: 'FBISE',
    p_units: [
      { title: 'Motion', topics: [{ title: 'Speed' }] },
      { title: 'Force', topics: [{ title: 'Newton' }] },
      { title: 'Energy' },
      { title: 'Heat' },
      { title: 'Waves', topics: [{ title: 'Sound' }] },
    ],
  });
  expect(syllabusError).toBeNull();
  const { data: units } = await db.from('syllabus_unit').select('id, sequence').eq('tenant_id', tenant).order('sequence');
  for (const u of units!.slice(0, 4)) {
    const { error } = await owner$.rpc('set_syllabus_coverage', { p_section_id: section!.id, p_subject_id: subject!.id, p_unit_id: u.id, p_status: u.sequence <= 3 ? 'completed' : 'in_progress' });
    expect(error).toBeNull();
  }

  const email = `ec-${tenant.slice(0, 8)}@paper-e2e.test`;
  const { data: created } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: created.user!.id, tenant_id: tenant, app_role: 'exam_controller', full_name: 'Exam Controller' });
  await db.from('user_campus').insert({ user_id: created.user!.id, tenant_id: tenant, campus_id: campusId });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/papers');
  await page.getByTestId('paper-title').fill('Term 1 Physics');
  await page.getByLabel(/5\. Waves/).check();
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('paper-error')).toHaveText('Chapter 5 Waves has not been taught yet — remove it or update coverage');
  await expect(page.getByTestId('paper-row')).toHaveCount(0);

  await page.getByLabel(/5\. Waves/).uncheck();
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('paper-row')).toHaveCount(1);

  // The worker (stubbed by the dev generator) claims the request and answers it.
  const { data: claimed } = await db.rpc('claim_exam_paper_request');
  const job = claimed![0]!;
  const payload = paperPayloadSchema.parse(job.payload);
  expect(payload.metadata_filter.syllabus_unit_id).toHaveLength(4);
  const questions = await new DevPaperGenerator().generate(payload);
  const { error: recordError } = await db.rpc('record_generated_paper', { p_request_id: job.request_id, p_questions: questions });
  expect(recordError).toBeNull();

  await page.getByRole('link', { name: 'Term 1 Physics' }).click();
  await expect(page.getByTestId('paper-question').first()).toBeVisible();
  await expect(page.getByTestId('question-source').first()).toContainText('chapter 1. Motion');
  await expect(page.getByTestId('question-source').first()).toContainText('topic: Speed');

  // Explicit override by the Exam Controller.
  await page.goto('/exams/papers');
  await page.getByTestId('paper-title').fill('Full syllabus');
  await page.getByLabel(/5\. Waves/).check();
  await page.getByTestId('untaught-override').check();
  await page.getByTestId('request-paper').click();
  await expect(page.getByTestId('paper-row')).toHaveCount(2);
  const { data: over } = await db.from('exam_paper_request').select('untaught_override, override_by').eq('title', 'Full syllabus').single();
  expect(over!.untaught_override).toBe(true);
  expect(over!.override_by).toBe(created.user!.id);
});
