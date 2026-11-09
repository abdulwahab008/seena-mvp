import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the student list filters by class, gender and parent phone', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('student-list-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const session = await must(db.from('academic_session').select('id').eq('tenant_id', tenant_id).single());
  const level = await must(db.from('class_level').select('id').eq('tenant_id', tenant_id).eq('code', '5').single());
  const base = { tenant_id, campus_id, session_id: session.id, class_level_id: level.id };
  const section = await must(db.from('class_section').insert({ ...base, name: 'A', capacity: 30 }).select('id').single());
  const mk = (gr: string, name: string, gender: 'male' | 'female') =>
    must(db.from('student').insert({ tenant_id, campus_id, gr_number: `${gr}-${runId}`, name_en: name, father_name_en: `Father of ${name}`, dob: '2015-01-01', gender, status: 'active' }).select('id').single());
  const ali = await mk('L1', 'Ali Raza', 'male');
  await mk('L2', 'Hina Noor', 'female');
  await must(db.from('enrolment').insert({ ...base, section_id: section.id, student_id: ali.id }).select('id').single());
  const father = await must(db.from('guardian').insert({ tenant_id, name_en: 'Raza', phone_e164: '+923001112233' }).select('id').single());
  await must(db.from('student_guardian').insert({ tenant_id, student_id: ali.id, guardian_id: father.id, relationship: 'father', is_primary: true, receives_billing: true }).select('student_id').single());

  await signInAs(page, owner.email);
  await page.goto('/students');
  const rows = page.locator('[data-testid^="student-row-"]');
  await expect(rows).toHaveCount(2);
  await expect(page.getByTestId(`student-row-L1-${runId}`)).toContainText('Class 5 A');
  await expect(page.getByTestId(`student-row-L1-${runId}`)).toContainText('03001112233');

  await page.getByLabel('Class').selectOption({ label: 'Class 5 A' });
  await page.getByTestId('student-filters').getByRole('button', { name: 'Search' }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Ali Raza');

  await page.goto('/students?gender=female');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Hina Noor');

  await page.goto('/students');
  await page.getByLabel('Search by').selectOption('phone');
  await page.getByLabel('Search text').fill('0300-1112233');
  await page.getByTestId('student-filters').getByRole('button', { name: 'Search' }).click();
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Ali Raza');
});
