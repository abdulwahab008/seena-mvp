import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-R04: issue a laptop to a staff member, see exit clearance blocked, record the return and see it cleared.

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('custody blocks the exit clearance until the asset is returned', async ({ page }) => {
  test.setTimeout(120000);
  const { owner$, email, campusId } = await seedFeesTenant(0, 'custody-e2e');
  const { error: assetError } = await owner$.rpc('create_asset', {
    p_campus_id: campusId, p_tag_no: 'IT-0042', p_name: 'Staff laptop', p_category: 'it', p_purchased_on: '2026-01-01', p_capitalised_cost: 15000000, p_useful_life_months: 36,
  });
  expect(assetError).toBeNull();
  const { error: staffError } = await owner$.rpc('create_staff', { p_campus_id: campusId, p_full_name: 'Leaving Teacher', p_gender: 'female', p_cnic: '42101-1234568-2' });
  expect(staffError).toBeNull();

  await signIn(page, email);
  await page.goto('/assets/custody');
  const issue = page.getByTestId('issue-form');
  await issue.getByLabel('Asset').selectOption({ index: 1 });
  await issue.getByLabel('Issue to').selectOption({ label: 'Staff · Leaving Teacher' });
  await issue.getByLabel('Issued on').fill('2026-03-01');
  await page.getByTestId('issue-form-submit').click();
  await expect(page.getByTestId('custody-row')).toHaveCount(1);
  await expect(page.getByTestId('custody-row')).toContainText('IT-0042');

  // a second issue without a return is refused
  await issue.getByLabel('Asset').selectOption({ index: 1 });
  await issue.getByLabel('Issue to').selectOption({ label: 'Staff · Leaving Teacher' });
  await page.getByTestId('issue-form-submit').click();
  await expect(page.getByTestId('issue-form-error')).toContainText('already in someone');

  await page.getByLabel('Staff member').selectOption({ index: 1 });
  await page.getByTestId('clearance-check').click();
  await expect(page.getByTestId('clearance-blocked')).toContainText('IT-0042');

  const ret = page.getByTestId('return-form');
  await ret.getByLabel('Custody').selectOption({ index: 1 });
  await ret.getByLabel('Condition on return').selectOption('good');
  await page.getByTestId('return-form-submit').click();
  await expect(page.getByTestId('custody-row')).toHaveCount(0);

  await page.goto('/assets/custody?asof=2026-05-01');
  await expect(page.getByTestId('asof-row')).toContainText('Leaving Teacher');
  await page.getByLabel('Staff member').selectOption({ index: 1 });
  await page.getByTestId('clearance-check').click();
  await expect(page.getByTestId('clearance-ok')).toBeVisible();
});
