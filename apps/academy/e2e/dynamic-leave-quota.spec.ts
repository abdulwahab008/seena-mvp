import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { seedSchoolOwner } from './support/school-owner-seed';

test('dynamic leave policy quota customization and recalculation', async ({ page }) => {
  // 1. Log in as Owner
  const owner = await seedSchoolOwner('leave-quota');
  // The standard leave policies (Casual 10, Sick 8, ...) are created by the owner-only
  // initialize_school_leave_policies(); a freshly provisioned school starts without them.
  const ownerClient = createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321',
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    { auth: { persistSession: false } },
  );
  const { error: signInError } = await ownerClient.auth.signInWithPassword({
    email: owner.email,
    password: owner.password,
  });
  if (signInError) throw signInError;
  const { error: policyError } = await ownerClient.rpc('initialize_school_leave_policies');
  if (policyError) throw policyError;
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel('Password').fill(owner.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('**/dashboard', { timeout: 15000 });

  // 2. Navigate to Leave Hub
  await page.goto('/leave');
  await page.waitForLoadState('networkidle');

  // 3. Switch to Policies tab
  const policiesTab = page.getByRole('button', { name: /Policies & Quotas/i });
  await policiesTab.click();
  await page.waitForTimeout(300);


  // 4. Click "Edit" on Casual Leave (row with CASUAL)
  const casualRow = page.locator('tr:has-text("CASUAL")');
  await casualRow.getByRole('button', { name: 'Edit' }).click();

  // Verify modal is open
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Edit Policy Quota: Casual Leave')).toBeVisible();


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
  

  await page.getByRole('button', { name: 'Create Policy' }).click();
  await expect(page.getByText('Created leave policy "Professional Study Leave".')).toBeVisible();

  // 7. Verify the banner dynamically recalculated to 25 Days (12 + 8 + 5 = 25)
  await expect(page.getByText(/School Annual Paid Leave Quota: 25 Days per Year/i)).toBeVisible();


  // 8. Test resetting back to standard policies
  await page.getByRole('button', { name: 'Reset Standard Quotas' }).first().click();
  await expect(page.getByText('Standard school leave policies synchronized successfully.')).toBeVisible();
  await page.reload();
  await page.waitForLoadState('networkidle');
});
