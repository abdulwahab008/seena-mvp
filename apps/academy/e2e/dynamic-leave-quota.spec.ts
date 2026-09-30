import { test, expect } from '@playwright/test';

test('dynamic leave policy quota customization and recalculation', async ({ page }) => {
  // 1. Log in as Owner
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill('owner@seena.academy');
  await page.getByLabel('Password').fill('Password123!');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('**/dashboard', { timeout: 15000 });

  // 2. Navigate to Leave Hub
  await page.goto('/leave');
  await page.waitForLoadState('networkidle');

  // 3. Switch to Policies tab
  const policiesTab = page.getByRole('button', { name: /Policies & Quotas/i });
  await policiesTab.click();
  await page.waitForTimeout(300);

  // Take screenshot of initial policies tab
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/dynamic_leave_policies_initial.png',
  });

  // 4. Click "Edit" on Casual Leave (row with CASUAL)
  const casualRow = page.locator('tr:has-text("CASUAL")');
  await casualRow.getByRole('button', { name: 'Edit' }).click();

  // Verify modal is open
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Edit Policy Quota: Casual Leave')).toBeVisible();

  // Screenshot of Edit Policy Modal
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/leave_policy_modal_edit.png',
  });

  // Change quota from 10 to 12 days
  await page.locator('#policy-days').fill('12');
  await page.getByRole('button', { name: 'Update Policy' }).click();

  // Verify success toast
  await expect(page.getByText('Updated "Casual Leave" quota to 12 days.')).toBeVisible();

  // 5. Verify the banner dynamically updated to 20 Days (12 Casual + 8 Sick)
  await expect(page.getByText(/School Annual Paid Leave Quota: 20 Days per Year/i)).toBeVisible();

  // 6. Add a custom leave policy: STUDY (5 days, Fully Paid)
  await page.getByRole('button', { name: 'Add Leave Policy' }).first().click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Add Custom Leave Category')).toBeVisible();

  await page.locator('#policy-code').fill('STUDY');
  await page.locator('#policy-name').fill('Professional Study Leave');
  await page.locator('#policy-days').fill('5');
  
  // Screenshot of Add Policy Modal
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/leave_policy_modal_add.png',
  });

  await page.getByRole('button', { name: 'Create Policy' }).click();
  await expect(page.getByText('Created leave policy "Professional Study Leave".')).toBeVisible();

  // 7. Verify the banner dynamically recalculated to 25 Days (12 + 8 + 5 = 25)
  await expect(page.getByText(/School Annual Paid Leave Quota: 25 Days per Year/i)).toBeVisible();

  // Screenshot of dynamically updated dashboard
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/dynamic_leave_policies_customized.png',
  });

  // 8. Test resetting back to standard policies
  await page.getByRole('button', { name: 'Reset Standard Quotas' }).first().click();
  await expect(page.getByText('Standard school leave policies synchronized successfully.')).toBeVisible();
  await page.reload();
  await page.waitForLoadState('networkidle');
});
