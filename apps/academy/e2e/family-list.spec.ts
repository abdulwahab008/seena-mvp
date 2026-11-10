import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('the family list groups siblings and finds a family by CNIC', async ({ page }) => {
  const { db, tenantId: tenant_id, campusId: campus_id, runId, owner } = await seedHrTenant('family-list-e2e');
  const must = async (q: PromiseLike<{ data: unknown; error: { message: string } | null }>): Promise<{ id: string }> => {
    const { data, error } = await q;
    if (error || !data) throw new Error(error?.message ?? 'no data');
    return data as { id: string };
  };
  const father = await must(db.from('guardian').insert({ tenant_id, name_en: 'Tariq Mehmood', phone_e164: '+923005556677' }).select('id').single());
  const family = await must(db.from('family_group').insert({ tenant_id, father_cnic: '3520112345671', primary_guardian_id: father.id }).select('id').single());
  for (const [gr, name] of [['F1', 'Ayesha Tariq'], ['F2', 'Bilal Tariq']]) {
    await must(db.from('student').insert({ tenant_id, campus_id, family_group_id: family.id, gr_number: `${gr}-${runId}`, name_en: name, dob: '2015-01-01', gender: 'female', status: 'active' }).select('id').single());
  }
  await must(db.from('family_group').insert({ tenant_id, father_cnic: '3520199999991' }).select('id').single());

  await signInAs(page, owner.email);
  await page.goto('/students/families');
  const rows = page.getByTestId('family-row');
  await expect(rows).toHaveCount(1);
  await expect(rows.first()).toContainText('Tariq Mehmood');
  await expect(rows.first()).toContainText('03005556677');
  await expect(rows.first()).toContainText('Ayesha Tariq');
  await expect(rows.first()).toContainText('Bilal Tariq');

  await page.getByLabel('Search families').fill('35201-1234567-1');
  await page.getByRole('main').getByRole('button', { name: 'Search' }).click();
  await expect(rows).toHaveCount(1);
  await page.goto('/students/families?q=nobody');
  await expect(rows).toHaveCount(0);
});
