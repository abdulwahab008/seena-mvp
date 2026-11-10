import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the discipline register lists incidents school-wide and filters by severity', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('discipline-e2e');
  const { data: student, error } = await db
    .from('student')
    .insert({ tenant_id, campus_id, gr_number: `D1-${runId}`, name_en: 'Umar Farooq', dob: '2014-01-01', gender: 'male', status: 'active' })
    .select('id')
    .single();
  if (error) throw new Error(error.message);
  const base = { tenant_id, campus_id, student_id: student!.id, recorded_by: owner.userId };
  const { error: ierr } = await db.from('student_incident').insert([
    { ...base, occurred_on: '2026-11-02', category: 'uniform', severity: 'minor', description: 'No tie', parent_informed: false },
    { ...base, occurred_on: '2026-11-03', category: 'bullying', severity: 'serious', description: 'Pushed a junior', parent_informed: true },
  ]);
  if (ierr) throw new Error(ierr.message);

  await signInAs(page, owner.email);
  await page.goto('/students/discipline');
  const rows = page.getByTestId('incident-row');
  await expect(rows).toHaveCount(2);
  await expect(rows.first()).toContainText('Pushed a junior');
  await page.getByLabel('Severity').selectOption('serious');
  await page.getByRole('main').getByRole('button', { name: 'Search' }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Umar Farooq');
});
