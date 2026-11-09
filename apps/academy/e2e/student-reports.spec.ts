import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the strength report counts boys and girls per section and the reports hub links to it', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('student-reports-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 30 }).select('id').single());
  for (const [gr, gender] of [['R1', 'male'], ['R2', 'male'], ['R3', 'female']] as const) {
    const s = await must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${gr}-${runId}`, name_en: gr, dob: '2015-01-01', gender, status: 'active' }).select('id').single());
    await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: s.id }).select('id').single());
  }

  await signInAs(page, owner.email);
  await page.goto('/students/reports');
  await page.getByTestId('report-row').filter({ hasText: 'Student strength report' }).getByRole('link', { name: 'View' }).click();
  await expect(page.getByRole('heading', { name: 'Student strength report' })).toBeVisible();
  await expect(page.getByTestId('strength-row')).toHaveCount(1);
  await expect(page.getByTestId('strength-row').locator('td')).toHaveText(['Class 5', 'A', '2', '1', '3']);

  await page.goto('/students/reports/admission-form');
  await expect(page.getByRole('heading', { name: 'Admission form' })).toBeVisible();
});
