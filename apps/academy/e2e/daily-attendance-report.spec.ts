import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';
import { todayPk } from './support/today';

test('the daily attendance report lists absent students and late staff for the day', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner, mkUser } = await seedHrTenant('daily-att-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 30 }).select('id').single());
  for (const [name, status] of [['Hamza Ali', 'absent'], ['Iqra Khan', 'present']] as const) {
    const s = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${name[0]}-${runId}`, name_en: name, dob: '2015-01-01', gender: 'male', status: 'active' }).select('id').single());
    const e = await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: s.id }).select('id').single());
    await must(db.from('attendance_day').insert({ tenant_id, campus_id, session_id: session.id, section_id: section.id, enrolment_id: e.id, attendance_date: todayPk(), status }).select('id').single());
  }
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  await must(db.from('staff_attendance').insert({ tenant_id, campus_id, staff_id: teacher.staffId!, att_date: todayPk(), status: 'late' }).select('id').single());

  await signInAs(page, owner.email);
  await page.goto('/attendance/daily-report');
  await expect(page.getByRole('region', { name: 'Summary' })).toContainText('Absent1');
  await page.getByRole('link', { name: 'Absent list' }).click();
  await expect(page).toHaveURL(/status=absent/);
  await expect(page.getByTestId('daily-attendance-row')).toHaveCount(1);
  await expect(page.getByTestId('daily-attendance-row')).toContainText('Hamza Ali');
  await expect(page.getByTestId('daily-attendance-row')).toContainText('Class 5 A');

  await page.getByRole('navigation', { name: 'Who' }).getByRole('link', { name: 'Staff' }).click();
  await expect(page).toHaveURL(/who=staff/);
  await page.getByRole('link', { name: 'Late list' }).click();
  await expect(page).toHaveURL(/status=late/);
  await expect(page.getByTestId('daily-attendance-row')).toContainText('teacher user');
});
