import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-I10: the exam controller auto-assigns invigilators. Every paper gets its count, nobody invigilates their own
// subject, an infeasible paper is reported by name, and a teacher sees only their own duties.

test('auto-assign invigilators fairly, report the under-staffed paper, and show a teacher their own duties', async ({ page, browser, baseURL }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(0, 'invig-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();
  const { data: section } = await db.from('class_section').select('id').eq('tenant_id', tenant).single();

  const subjectIds: string[] = [];
  const csIds: string[] = [];
  for (const [code, name] of [['S1', 'Physics'], ['S2', 'Urdu'], ['S3', 'History']] as const) {
    const { data: s } = await db.from('subject').insert({ tenant_id: tenant, code, name_en: name, name_ur: name }).select('id').single();
    subjectIds.push(s!.id);
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
  const { data: ds } = await owner$.rpc('create_datesheet', { p_campus_id: campusId, p_exam_term_id: term as string, p_title: 'First Term datesheet' });
  for (const [i, es] of examSubjects.entries()) {
    const { error } = await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: es, p_exam_date: `2026-09-${String(8 + i).padStart(2, '0')}`, p_start_time: '09:00', p_end_time: '11:00', p_invigilators: 2 });
    expect(error).toBeNull();
  }

  // Six teachers; the first teaches Physics (the first paper) to the class.
  const staff: { id: string; email: string }[] = [];
  for (let n = 1; n <= 6; n++) {
    const staffEmail = `teacher${n}-${tenant.slice(0, 8)}@invig-e2e.test`;
    const { data: u } = await db.auth.admin.createUser({ email: staffEmail, password: SEED_PASSWORD, email_confirm: true });
    await db.from('app_user').insert({ user_id: u.user!.id, tenant_id: tenant, app_role: 'subject_teacher', full_name: `Teacher ${n}` });
    await db.from('user_campus').insert({ user_id: u.user!.id, tenant_id: tenant, campus_id: campusId });
    const { error } = await db.from('staff').insert({ tenant_id: tenant, campus_id: campusId, user_id: u.user!.id, employee_code: `E${n}`, cnic: `1110${n}-000000${n}-1`, gender: 'female', full_name: `Teacher ${n}` });
    expect(error).toBeNull();
    staff.push({ id: u.user!.id, email: staffEmail });
  }
  await db.from('section_subject_teacher').insert({ tenant_id: tenant, campus_id: campusId, session_id: session!.id, section_id: section!.id, subject_id: subjectIds[0]!, staff_id: staff[0]!.id, effective_from: '2000-01-01' });

  const signIn = async (p: import('@playwright/test').Page, address: string) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(address);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await expect(p).not.toHaveURL(/\/login/);
  };

  await signIn(page, email);
  await page.goto('/exams/invigilation');
  await page.getByTestId('run-assignment').click();
  await expect(page.getByTestId('assign-report')).toContainText('6 duties assigned');
  await expect(page.getByTestId('slot-fill')).toHaveCount(3);
  for (const badge of await page.getByTestId('slot-fill').all()) await expect(badge).toHaveText('2 of 2');

  // Nobody invigilates the subject they teach.
  const { data: physicsSlot } = await db.from('datesheet_slot').select('id').eq('exam_subject_id', examSubjects[0]!).single();
  const { data: onPhysics } = await db.from('invigilation_duty').select('staff_id').eq('datesheet_slot_id', physicsSlot!.id).eq('status', 'assigned');
  expect(onPhysics!.map((d) => d.staff_id)).not.toContain(staff[0]!.id);

  // Seven invigilators for History with six staff: the paper is reported by name, not silently under-assigned.
  const { error: bumpError } = await owner$.rpc('save_datesheet_slot', { p_datesheet_id: ds as string, p_exam_subject_id: examSubjects[2]!, p_exam_date: '2026-09-10', p_start_time: '09:00', p_end_time: '11:00', p_invigilators: 7 });
  expect(bumpError).toBeNull();
  await page.reload();
  await page.getByTestId('run-assignment').click();
  await expect(page.getByTestId('understaffed-slot')).toHaveCount(1);
  await expect(page.getByTestId('understaffed-slot')).toContainText('History');
  await expect(page.getByTestId('understaffed-slot')).toContainText('short by 1');

  // A teacher sees exactly their own duties.
  const { data: theirs } = await db.from('invigilation_duty').select('id').eq('staff_id', staff[1]!.id).eq('status', 'assigned');
  const tctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const teacher = await tctx.newPage();
  await signIn(teacher, staff[1]!.email);
  await teacher.goto('/exams/invigilation');
  await expect(teacher.getByTestId('my-duty')).toHaveCount(theirs!.length);
  await expect(teacher.getByTestId('run-assignment')).toHaveCount(0);
  await tctx.close();
});
