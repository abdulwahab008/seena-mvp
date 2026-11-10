import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('curriculum reports flag a subject with no teacher and count the question bank', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, owner, mkUser } = await seedHrTenant('curriculum-reports-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const section = await must(db.from('class_section').insert({ tenant_id, campus_id, session_id: session.id, class_level_id: level.id, name: 'A', capacity: 30 }).select('id').single());
  const maths = await must(db.from('subject').insert({ tenant_id, code: 'MTH', name_en: 'Maths' }).select('id').single());
  const urdu = await must(db.from('subject').insert({ tenant_id, code: 'URD', name_en: 'Urdu' }).select('id').single());
  for (const s of [maths, urdu]) {
    await must(db.from('class_subject').insert({ tenant_id, campus_id, session_id: session.id, class_level_id: level.id, subject_id: s.id, weekly_periods: 5 }).select('id').single());
  }
  const teacher = await mkUser('maths-teacher', 'subject_teacher', { staff: {} });
  await must(
    db.from('section_subject_teacher').insert({ tenant_id, campus_id, session_id: session.id, section_id: section.id, subject_id: maths.id, staff_id: teacher.userId, role: 'primary', effective_from: '2026-01-01' }).select('id').single(),
  );
  for (const difficulty of ['easy', 'hard', 'hard']) {
    await must(db.from('question_bank_item').insert({ tenant_id, campus_id, subject_id: maths.id, class_level_id: level.id, question_type: 'short', question_text: `Q ${difficulty} ${Math.random()}`, difficulty, marks: 2 }).select('id').single());
  }

  const unit = await must(
    db.from('syllabus_unit').insert({ tenant_id, campus_id, session_id: session.id, class_level_id: level.id, subject_id: maths.id, board: 'PUNJAB', title: 'Fractions', sequence: 1, planned_periods: 10, target_month: '2026-09-01' }).select('id').single(),
  );
  await must(db.from('syllabus_topic').insert({ tenant_id, syllabus_unit_id: unit.id, title: 'Adding fractions', sequence: 1, planned_periods: 4 }).select('id').single());

  await signInAs(page, owner.email);
  await page.goto('/academic-setup/curriculum-reports');
  await expect(page.getByTestId('assignment-row').filter({ hasText: 'Maths' })).toContainText('maths-teacher user');
  await expect(page.getByTestId('assignment-row').filter({ hasText: 'Urdu' })).toContainText('No teacher');
  await expect(page.getByTestId('bank-row').locator('td')).toHaveText(['Maths', '1', '2', '3']);
  await expect(page.getByTestId('coverage-row').filter({ hasText: 'Maths' }).locator('td')).toHaveText(['Class 5', 'Maths', '1', '0%', '—', '1']);
  await expect(page.getByTestId('completeness-row').filter({ hasText: 'Maths' }).locator('td')).toHaveText(['Class 5', 'Maths', '1', '1', 'Yes', '3']);
  await expect(page.getByTestId('completeness-row').filter({ hasText: 'Urdu' }).locator('td')).toHaveText(['Class 5', 'Urdu', '0', '0', 'No', '0']);
});
