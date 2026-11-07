import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a teacher records a discipline incident, and graduated students show as alumni', async ({ page }) => {
  const seed = await seedFeesTenant(2, 'discipline');
  const { data: students } = await seed.db.from('student').select('id, name_en').eq('tenant_id', seed.tenant).order('name_en');
  await signInAs(page, seed.email);

  await page.goto(`/students/${students![0]!.id}`);
  await page.getByText('Record an incident').click();
  await page.getByLabel('Type').selectOption('bullying');
  await page.getByLabel('Severity').selectOption('serious');
  await page.getByLabel('What happened').fill('Pushed a younger student at break');
  await page.getByLabel('Action taken').fill('Parents called in');
  await page.getByLabel('Parent informed').check();
  await page.getByRole('button', { name: 'Save incident' }).click();
  await expect(page.getByTestId('incident-list')).toContainText('Pushed a younger student at break');
  await expect(page.getByTestId('incident-list')).toContainText('parent informed');

  await seed.db.from('student').update({ status: 'graduated' }).eq('id', students![1]!.id);
  await page.goto('/students/alumni');
  await expect(page.getByTestId('alumni-row')).toHaveCount(1);
  await expect(page.getByTestId('alumni-row')).toContainText(students![1]!.name_en);
});
