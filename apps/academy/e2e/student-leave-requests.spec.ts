import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the office approves a parent leave request', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('student-leave-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 30 }).select('id').single());
  const student = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `LV-${runId}`, name_en: 'Sara Ahmed', dob: '2015-01-01', gender: 'female', status: 'active' }).select('id').single());
  const enrolment = await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: student.id }).select('id').single());
  await must(
    db.from('student_leave_application').insert({ tenant_id, campus_id, session_id: session.id, enrolment_id: enrolment.id, applied_by_user_id: owner.userId, applied_via: 'parent', from_date: '2026-12-01', to_date: '2026-12-02', reason_category: 'medical', remarks: 'Fever' }).select('id').single(),
  );

  await signInAs(page, owner.email);
  await page.goto('/attendance/student-leaves');
  const row = page.getByTestId('leave-row').filter({ hasText: 'Sara Ahmed' });
  await expect(row).toContainText('Fever');
  await row.getByLabel('Decision note').fill('Get well soon');
  await row.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByText('Leave approved.')).toBeVisible();
  await expect(page.getByText('No pending leave requests.')).toBeVisible();
  await page.getByRole('link', { name: 'approved' }).click();
  await expect(page.getByTestId('leave-row').filter({ hasText: 'Sara Ahmed' })).toContainText('Get well soon');
});
