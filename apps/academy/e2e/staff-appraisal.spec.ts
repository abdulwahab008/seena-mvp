import { test, expect, type Page } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

// FR-D14: HR builds a cycle (weights must total 100 to publish), a short-service joiner is left out, the Principal
// scores and releases (80.00 for all 4s), the appraisee cannot see anything before release, then disputes and the Owner reads it.

const today = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
const addDays = (iso: string, n: number) => new Date(new Date(iso + 'T00:00:00Z').getTime() + n * 86_400_000).toISOString().slice(0, 10);

test('a weighted appraisal is hidden until released, scores 80.00, and a dispute reaches the Owner', async ({ page, browser, baseURL }) => {
  test.setTimeout(180000);
  const { db, tenantId, mkUser, owner } = await seedHrTenant('appr-e2e');
  const hr = await mkUser('hrmanager', 'hr_manager');
  const principal = await mkUser('principal', 'principal');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: { doj: '2020-01-01' } });
  await mkUser('joiner', 'subject_teacher', { staff: { doj: addDays(today(), -45) } });

  await signInAs(page, hr.email);
  await page.goto('/staff/appraisals');
  await page.getByLabel('Name', { exact: true }).fill('2026 annual appraisal');
  await page.getByLabel('Opens').fill(addDays(today(), -30));
  await page.getByLabel('Closes').fill(today());
  // weights add up to 99: the cycle can be saved as a draft but not published
  await page.getByLabel(/Competencies and weights/).fill('Subject knowledge | 25\nLesson planning | 20\nClassroom management | 20\nAssessment and feedback | 15\nProfessionalism | 10\nCommunication | 9');
  await expect(page.getByTestId('weights-hint')).toContainText('not 100');
  await page.getByTestId('create-cycle').click();
  await expect(page.getByTestId('cycle-status')).toHaveText('draft');
  await page.getByTestId('publish-cycle').click();
  await expect(page.getByTestId('publish-error')).toContainText('exactly 100');

  await page.getByLabel('Competencies and weights').fill('Subject knowledge | 25\nLesson planning | 20\nClassroom management | 20\nAssessment and feedback | 15\nProfessionalism | 10\nCommunication | 10');
  await page.getByTestId('save-competencies').click();
  await page.getByTestId('publish-cycle').click();
  await expect(page.getByTestId('cycle-status')).toHaveText('published');
  await expect(page.getByTestId('report-eligible')).toHaveText('1');
  await expect(page.getByTestId('report-excluded')).toContainText('45 days');
  const { data: ap } = await db.from('appraisal').select('id').eq('tenant_id', tenantId).single();

  const open = async (email: string): Promise<Page> => {
    const ctx = await browser.newContext({ baseURL: baseURL ?? undefined });
    const p = await ctx.newPage();
    await signInAs(p, email);
    return p;
  };

  // before release the appraisee cannot see the appraisal at all
  const tp = await open(teacher.email);
  const before = await tp.goto(`/staff/appraisals/${ap!.id}`);
  expect(before!.status()).toBe(404);

  // the Principal scores and releases
  const pp = await open(principal.email);
  await pp.goto('/staff/appraisals');
  await pp.getByTestId('rate-row').first().getByRole('link').click();
  for (const label of ['Subject knowledge', 'Lesson planning', 'Classroom management', 'Assessment and feedback', 'Professionalism', 'Communication']) {
    await pp.getByLabel(label).selectOption('4');
  }
  await expect(pp.getByTestId('score-preview')).toContainText('80.00');
  await pp.getByTestId('save-scores').click();
  await expect.poll(async () => (await db.from('appraisal_score').select('rating').eq('appraisal_id', ap!.id)).data?.length).toBe(6);
  await pp.getByTestId('release-appraisal').click();
  await expect(pp.getByTestId('appraisal-status')).toHaveText('released');

  // the appraisee now sees the score and disputes it
  await tp.goto(`/staff/appraisals/${ap!.id}`);
  await expect(tp.getByTestId('appraisal-total')).toContainText('80.00');
  await tp.getByLabel(/record your response/i).fill('I disagree with the classroom management rating.');
  await tp.getByTestId('dispute-appraisal').click();
  await expect(tp.getByTestId('appraisal-status')).toHaveText('awaiting acknowledgement');

  // the Owner can read the response
  const op = await open(owner.email);
  await op.goto(`/staff/appraisals/${ap!.id}`);
  await expect(op.getByTestId('appraisee-comment')).toContainText('classroom management rating');
});
