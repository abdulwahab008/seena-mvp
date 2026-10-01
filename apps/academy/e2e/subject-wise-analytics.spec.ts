import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J06: subject-wise analytics.
//
//   AC1  62 / 55 / 71 in Chemistry beside section averages 58 / 60 / 64.
//   AC2  fewer than 5 ranked candidates -> "too few students to compare".
//   AC3  a parent sees their own child's series only.
//   AC4  a term with no locked marks is omitted, not plotted as zero.

test('a parent sees their child against the section average; a small section is suppressed', async ({ page, browser, baseURL }) => {
  test.setTimeout(150000);
  const { db, email: ownerEmail, tenant, campusId, challans } = await seedFeesTenant(6, 'trend-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db
    .from('subject')
    .insert({ tenant_id: tenant, code: 'CHM', name_en: 'Chemistry', name_ur: 'کیمیا' })
    .select('id')
    .single();
  const { data: classSubject } = await db
    .from('class_subject')
    .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, class_level_id: section!.class_level_id, subject_id: subject!.id, weekly_periods: 5 })
    .select('id')
    .single();

  const mkTerm = async (code: string, name: string, sequence: number) => {
    const { data, error } = await db
      .from('exam_term')
      .insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, code, name, sequence, weight_bp: 0, counts_toward_annual: false, status: 'active' })
      .select('id')
      .single();
    if (error) throw error;
    const { data: es } = await db.from('exam_subject').insert({ tenant_id: tenant, campus_id: campusId, exam_term_id: data!.id, class_subject_id: classSubject!.id }).select('id').single();
    return { termId: data!.id, examSubjectId: es!.id };
  };
  const terms = [await mkTerm('T1', 'First Term', 1), await mkTerm('T2', 'Mid Term', 2), await mkTerm('T3', 'Final Term', 3)];
  await mkTerm('T4', 'Pre-Board', 4); // never locked: must not appear

  const enrolments = challans.map((c) => c.enrolment_id);
  const scores = [
    [62, 55, 71],
    [55, 61, 62],
    [57, 61, 63],
    [58, 61, 63],
    [58, 61, 63],
    [58, 61, 62],
  ];
  const rows = enrolments.flatMap((enrolmentId, i) =>
    terms.map((t, j) => ({
      tenant_id: tenant,
      campus_id: campusId,
      exam_term_id: t.termId,
      section_id: section!.id,
      exam_subject_id: t.examSubjectId,
      enrolment_id: enrolmentId,
      subject_id: subject!.id,
      obtained: scores[i]![j]!,
      max_marks: 100,
      pct: scores[i]![j]!,
      is_pass: true,
    })),
  );
  const { error: insertError } = await db.from('subject_result').insert(rows);
  expect(insertError).toBeNull();
  const { error: refreshError } = await db.rpc('fn_refresh_subject_averages', { p_exam_term_id: terms[0]!.termId });
  expect(refreshError).toBeNull();

  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', enrolments[0]!).single();
  const parentEmail = `parent-${randomUUID().slice(0, 8)}@trend-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db
    .from('guardian')
    .insert({ tenant_id: tenant, name_en: 'Trend Parent', phone_e164: '+923001239999', auth_user_id: user.user!.id })
    .select('id')
    .single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'mother', is_primary: true, receives_academic: true });

  const signIn = async (p: import('@playwright/test').Page, addr: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(addr);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await expect(p).not.toHaveURL(/\/login/);
  };

  // Parent: AC1, AC3, AC4.
  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signIn(pp, parentEmail);
  await pp.goto('/portal/results/trend');
  const chart = pp.getByTestId('trend-Chemistry');
  await expect(chart).toBeVisible();
  await expect(chart.getByTestId('trend-point-Chemistry')).toHaveCount(3);
  await expect(pp.getByTestId('trend-row-Chemistry-First Term')).toContainText('62%');
  await expect(pp.getByTestId('trend-row-Chemistry-First Term')).toContainText('58%');
  await expect(pp.getByTestId('trend-row-Chemistry-Mid Term')).toContainText('55%');
  await expect(pp.getByTestId('trend-row-Chemistry-Mid Term')).toContainText('60%');
  await expect(pp.getByTestId('trend-row-Chemistry-Final Term')).toContainText('71%');
  await expect(pp.getByTestId('trend-row-Chemistry-Final Term')).toContainText('64%');
  await expect(pp.getByText('Pre-Board')).toHaveCount(0);
  await expect(pp.getByText('Kid 2')).toHaveCount(0);
  await pctx.close();

  // Staff: AC2 once the section is small. Withhold three candidates' results
  // so only three ranked candidates remain, and refresh.
  await db.from('result_withhold').insert(
    enrolments.slice(3).flatMap((enrolmentId) =>
      terms.map((t) => ({ tenant_id: tenant, campus_id: campusId, exam_term_id: t.termId, enrolment_id: enrolmentId, reason: 'discipline', cutoff_date: new Date().toISOString().slice(0, 10) })),
    ),
  );
  await db.rpc('fn_refresh_subject_averages', { p_exam_term_id: terms[0]!.termId });
  await signIn(page, ownerEmail);
  await page.goto(`/exams/analytics?section=${section!.id}`);
  await expect(page.getByTestId('avg-Chemistry-First Term')).toContainText('too few students to compare');
});
