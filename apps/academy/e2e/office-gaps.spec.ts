import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

test('an owner places unsectioned students, sets teacher load rules, adds a package item and clears notifications', async ({ page }) => {
  test.setTimeout(150000);
  const { db, owner$, email, tenant, campusId } = await seedFeesTenant(1, 'office-gaps-e2e');
  for (const name of ['Unplaced One', 'Unplaced Two']) {
    const { error } = await owner$.rpc('create_student', { p_campus_id: campusId, p_name_en: name, p_dob: '2016-03-01', p_gender: 'female' });
    expect(error).toBeNull();
  }
  const { data: item } = await db.from('inv_item').insert({ tenant_id: tenant, item_code: 'BOOK-URD1', name: 'Urdu book 1', category: 'textbook', sale_price: 50000 }).select('id').single();
  expect(item).not.toBeNull();
  const { data: ownerRow } = await db.from('app_user').select('user_id').eq('tenant_id', tenant).eq('app_role', 'owner').single();
  await db.from('user_notification').insert({ tenant_id: tenant, user_id: ownerRow!.user_id, kind: 'export_ready', title: 'Export ready', body: 'Students export is ready.' });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/academic-setup/classes-sections');
  const place = page.getByTestId('auto-place');
  await place.getByLabel('Place Unplaced One').check();
  await place.getByLabel('Place Unplaced Two').check();
  await place.getByLabel('Class to place them in').selectOption({ index: 1 });
  await page.getByTestId('auto-place-submit').click();
  await expect(page.getByText('Placed 2 students in the emptiest sections.')).toBeVisible();
  await expect(page.getByTestId('auto-place')).toHaveCount(0);

  await page.goto('/academic-setup/timetable');
  const rules = page.getByTestId('timetable-rules-form');
  await rules.getByLabel('Most periods a day').fill('6');
  await rules.getByLabel('Most periods in a row').fill('3');
  await rules.getByLabel('Flag a single free period').selectOption('no');
  await page.getByTestId('timetable-rules-form-submit').click();
  await expect(page.getByTestId('timetable-rules')).toHaveText('A teacher is flagged above 6 periods a day or 3 periods in a row.');

  const { data: kid } = await db.from('student').select('gr_number').eq('tenant_id', tenant).eq('name_en', 'Unplaced One').single();
  await page.goto(`/inventory/sales?gr=${kid!.gr_number}`);
  await page.getByText("Add an item to this student's admission package (free)").click();
  const grant = page.getByTestId('grant-package-form');
  await grant.getByLabel('Item').selectOption({ label: 'BOOK-URD1 · Urdu book 1' });
  await grant.getByLabel('Quantity').fill('2');
  await page.getByTestId('grant-package-form-submit').click();
  await expect(page.getByTestId('package-notice')).toContainText('Urdu book 1 × 2');

  await page.goto('/reports/exports');
  await expect(page.locator('[data-unread="true"]')).toHaveCount(1);
  await page.getByTestId('mark-notifications-read').click();
  await expect(page.locator('[data-unread="true"]')).toHaveCount(0);
  await expect(page.getByTestId('mark-notifications-read')).toHaveCount(0);
});
