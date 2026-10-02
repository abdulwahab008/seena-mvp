import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-H10: a teacher plans a week from the syllabus (date normalised to Monday), completes it, and the Principal sees it read-only.

test('a teacher plans a week from the syllabus and completes it; the Principal sees it read-only', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId } = await seedFeesTenant(0, 'plan-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: section } = await db.from('class_section').select('id, class_level_id').eq('tenant_id', tenant).single();
  const { data: subject } = await db.from('subject').insert({ tenant_id: tenant, code: 'PHY', name_en: 'Physics', name_ur: 'طبیعیات' }).select('id').single();
  const { error: syllabusError } = await owner$.rpc('save_syllabus', {
    p_campus_id: campusId, p_session_id: session!.id, p_class_level_id: section!.class_level_id, p_subject_id: subject!.id, p_board: 'FBISE',
    p_units: [{ title: 'Motion', topics: [{ title: 'Speed' }, { title: 'Velocity' }] }],
  });
  expect(syllabusError).toBeNull();

  const mk = async (suffix: string, role: string) => {
    const email = `${suffix}-${tenant.slice(0, 8)}@plan-e2e.test`;
    const { data } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
    await db.from('app_user').insert({ user_id: data.user!.id, tenant_id: tenant, app_role: role, full_name: `${suffix} user` });
    await db.from('user_campus').insert({ user_id: data.user!.id, tenant_id: tenant, campus_id: campusId });
    return { email, id: data.user!.id };
  };
  const teacher = await mk('teacher', 'subject_teacher');
  const principal = await mk('principal', 'principal');
  await db.from('section_subject_teacher').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, subject_id: subject!.id, staff_id: teacher.id, effective_from: '2000-01-01' });

  const signIn = async (p: import('@playwright/test').Page, email: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(email);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await expect(p).not.toHaveURL(/\/login/);
  };

  await signIn(page, teacher.email);
  await page.goto('/lesson-plans?week=2026-09-09');
  await expect(page.getByTestId('topic-picker')).toContainText('Speed');
  await page.getByLabel(/Learning objectives/).fill('Understand speed');
  await page.getByLabel('Speed', { exact: true }).check();
  await page.getByTestId('save-plan').click();
  await expect(page.getByTestId('plan-row')).toHaveCount(1);
  await expect(page.getByTestId('plan-row')).toContainText('Speed');

  const { data: week } = await db.from('lesson_plan').select('week_start_date').eq('tenant_id', tenant).single();
  expect(week!.week_start_date).toBe('2026-09-07');

  await page.getByTestId('complete-plan').click();
  await expect(page.getByTestId('plan-row')).toContainText('completed');

  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signIn(pp, principal.email);
  await pp.goto('/lesson-plans?week=2026-09-07');
  await expect(pp.getByTestId('plan-row')).toHaveCount(1);
  await expect(pp.getByTestId('plan-row')).toContainText('teacher user');
  await expect(pp.getByTestId('complete-plan')).toHaveCount(0);
  await pctx.close();
});
