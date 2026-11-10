import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('a new appraisal cycle reuses the review criteria of an earlier one', async ({ page }) => {
  const { db, tenantId: tenant_id, owner } = await seedHrTenant('appr-copy-e2e');
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant_id).single();
  const mkCycle = async (name: string) => {
    const { data, error } = await db.from('appraisal_cycle').insert({ tenant_id, session_id: session!.id, name, opens_on: '2026-01-01', closes_on: '2026-06-30' }).select('id').single();
    if (error) throw new Error(error.message);
    return data!.id as string;
  };
  const last = await mkCycle('2025 review');
  const next = await mkCycle('2026 review');
  const { error } = await db.from('appraisal_competency').insert([
    { tenant_id, cycle_id: last, name: 'Teaching quality', weight_pct: 60, sort_order: 1 },
    { tenant_id, cycle_id: last, name: 'Punctuality', weight_pct: 40, sort_order: 2 },
  ]);
  if (error) throw new Error(error.message);

  await signInAs(page, owner.email);
  await page.goto(`/staff/appraisals/cycles/${next}`);
  await page.getByLabel('Copy criteria from').selectOption(last);
  await page.getByRole('button', { name: 'Copy', exact: true }).click();
  await expect(page.getByText('Copied 2 criteria. Save to keep them.')).toBeVisible();
  await expect(page.getByLabel('Competencies and weights')).toHaveValue('Teaching quality | 60\nPunctuality | 40');
  await page.getByTestId('save-competencies').click();
  await expect.poll(async () => (await db.from('appraisal_competency').select('name').eq('cycle_id', next)).data?.length).toBe(2);
});
