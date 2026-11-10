import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('class reports show seats filled and open a printable class list', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('class-reports-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 25 }).select('id').single());
  for (const name of ['Zain Ali', 'Amna Riaz']) {
    const s = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${name[0]}-${runId}`, name_en: name, dob: '2015-01-01', gender: 'male', status: 'active' }).select('id').single());
    await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: s.id }).select('id').single());
  }

  await signInAs(page, owner.email);
  await page.goto('/academic-setup/class-reports');
  const row = page.getByTestId('capacity-row').filter({ hasText: 'Class 5' });
  await expect(row.locator('td')).toHaveText(['Class 5', 'A', '25', '2', '23', 'View']);
  await row.getByRole('link', { name: 'View' }).click();
  await expect(page.getByRole('heading', { name: 'Class list: Class 5 A' })).toBeVisible();
  await expect(page.getByTestId('class-list-row')).toHaveCount(2);
  // Enrolling numbers students in join order, and the class list is in roll order.
  await expect(page.getByTestId('class-list-row').first()).toContainText('Zain Ali');
});
