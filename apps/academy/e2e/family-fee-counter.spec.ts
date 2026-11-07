import { test, expect } from '@playwright/test';
import { seedFeesTenant } from './support/fees-seed';
import { signInAs } from './support/hr-seed';
import { openCashShift } from './support/cash-shift';

test('a cashier takes one payment for two siblings at the family counter', async ({ page }) => {
  const seed = await seedFeesTenant(2, 'family');
  const { data: students } = await seed.db.from('student').select('id').eq('tenant_id', seed.tenant);
  const { data: familyId, error } = await seed.owner$.rpc('link_family_group', { p_student_ids: (students ?? []).map((s) => s.id) });
  if (error) throw error;
  const { data: family } = await seed.db.from('family_group').select('family_no').eq('id', familyId as string).single();

  await signInAs(page, seed.email);
  await openCashShift(page);

  await page.getByLabel(/Family no, parent CNIC/).fill(String(family!.family_no));
  await page.getByRole('button', { name: 'Find family' }).click();
  await expect(page.getByTestId('family-heading')).toContainText(`Family ${family!.family_no}`);
  await expect(page.getByTestId('family-total')).toHaveText('PKR 17,000.00');

  await page.getByLabel('Amount (Rs)').fill('10000');
  await page.getByRole('button', { name: 'Receive payment' }).click();
  await expect(page.getByTestId('family-receipts').locator('li')).toHaveCount(2);
  await expect(page.getByTestId('family-total')).toHaveText('PKR 7,000.00');
});
