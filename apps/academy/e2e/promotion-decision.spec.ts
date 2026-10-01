import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-J04: end-of-session promotion decisions derived from the annual result by
// a configurable rule; the Principal overrides one with a reason.
//
//   AC1  one failed subject at a 55% aggregate -> Compartment, subject named.
//   AC2  three failed subjects -> Detained.
//   AC4  overriding Detained -> Promoted on trial stores the actor and reason.

test('the rule produces Compartment and Detained, and an override is recorded', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant, campusId, challans } = await seedFeesTenant(2, 'promo-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subjects } = await db
    .from('subject')
    .insert(
      ['MTH', 'PHY', 'ISL', 'ENG'].map((code, i) => ({
        tenant_id: tenant,
        code,
        name_en: ['Maths', 'Physics', 'Islamiat', 'English'][i]!,
        name_ur: ['ریاضی', 'طبیعیات', 'اسلامیات', 'انگریزی'][i]!,
      })),
    )
    .select('id, code');
  const subj = Object.fromEntries((subjects ?? []).map((s) => [s.code, s.id]));
  const [first, second] = challans.map((c) => c.enrolment_id);

  const row = (enrolmentId: string, subjectId: string, pct: number, pass: boolean) => ({
    tenant_id: tenant,
    campus_id: campusId,
    session_id: session!.id,
    class_level_id: section!.class_level_id,
    section_id: section!.id,
    enrolment_id: enrolmentId,
    subject_id: subjectId,
    weighted_pct: pct,
    is_pass: pass,
    status: 'final',
    terms_counted: 1,
    terms_total: 1,
    prorated_terms: 0,
    is_blocked: false,
  });
  const { error } = await db.from('annual_result').insert([
    row(first!, subj.MTH, 35, false),
    row(first!, subj.PHY, 70, true),
    row(first!, subj.ISL, 60, true),
    row(first!, subj.ENG, 55, true),
    row(second!, subj.MTH, 20, false),
    row(second!, subj.PHY, 25, false),
    row(second!, subj.ISL, 30, false),
    row(second!, subj.ENG, 60, true),
  ]);
  expect(error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/exams/promotion');
  await page.getByTestId('promotion-class-select').selectOption(section!.class_level_id);
  await page.getByTestId('open-promotion').click();
  await expect(page.getByTestId('promotion-sheet')).toBeVisible();
  await expect(page.getByTestId('promotion-rule-source')).toContainText('built-in default');
  await page.getByTestId('evaluate-promotion').click();
  await expect(page.getByTestId('promotion-table')).toBeVisible();

  const { data: students } = await db.from('student').select('gr_number, id').eq('tenant_id', tenant);
  const { data: enrolments } = await db.from('enrolment').select('id, student_id').in('id', [first!, second!]);
  const grOf = (enrolmentId: string) => {
    const studentId = enrolments!.find((e) => e.id === enrolmentId)!.student_id;
    return students!.find((s) => s.id === studentId)!.gr_number;
  };

  await expect(page.getByTestId(`promotion-decision-${grOf(first!)}`)).toContainText('Compartment');
  await expect(page.getByTestId(`promotion-${grOf(first!)}`)).toContainText('Maths');
  await expect(page.getByTestId(`promotion-decision-${grOf(second!)}`)).toContainText('Detained');

  await page.getByTestId(`override-${grOf(second!)}`).click();
  await page.getByTestId('override-target').selectOption('promoted_on_trial');
  await page.getByTestId('override-reason').fill('Parents appealed after a family bereavement');
  await page.getByTestId('override-save').click();
  await expect(page.getByTestId(`promotion-decision-${grOf(second!)}`)).toContainText('Promoted on trial');

  const { data: stored } = await db
    .from('promotion_decision')
    .select('decision, system_decision, override_reason, overridden_by')
    .eq('enrolment_id', second!)
    .single();
  expect(stored!.decision).toBe('promoted_on_trial');
  expect(stored!.system_decision).toBe('detained');
  expect(stored!.override_reason).toBe('Parents appealed after a family bereavement');
  expect(stored!.overridden_by).not.toBeNull();
});
