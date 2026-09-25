import { test, expect } from '@playwright/test';

test.describe('FR-M10: Message Cost Ledger and Prepaid Credit Guard', () => {
  test('Principal / Owner manages messaging wallet, inspects rate cards, credits balance and views cost ledger', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Credit & Wallet Desk
    await page.goto('/communication/wallet');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Title and Wallet Card
    await expect(page.locator('h1')).toContainText('Message Cost Ledger & Credit Guard');
    await expect(page.getByText('Prepaid Messaging Balance')).toBeVisible();
    await expect(page.getByText(/Exact ledger:/i)).toBeVisible();

    // 4. Verify Effective Rate Cards Tab
    await expect(page.getByText('Effective Rate Cards')).toBeVisible();
    await expect(page.getByText('Urdu (UCS-2)').first()).toBeVisible();
    await expect(page.getByText('English (GSM-7)').first()).toBeVisible();
    await expect(page.getByText('PKR 1.20 / unit').first()).toBeVisible();

    // 5. Perform Wallet Top-Up (PKR 10,000)
    await page.getByRole('button', { name: 'PKR 10,000' }).click();
    await page.getByPlaceholder('e.g. JazzCash Ref #88291').fill('Bank Transfer E2E Deposit #9981');
    await page.getByRole('button', { name: 'Add Credit to Wallet' }).click();

    // Verify confirmation notice
    await expect(page.getByText(/Wallet credited with PKR 10,000/i)).toBeVisible({ timeout: 10000 });

    // 6. Verify Transaction Audit Tab
    await page.getByRole('button', { name: /Wallet Transaction Audit/i }).click();
    await expect(page.getByText('Bank Transfer E2E Deposit #9981').first()).toBeVisible();
    await expect(page.getByText('+ PKR 10,000.00').first()).toBeVisible();

    // 7. Verify Cost Ledger Entries Tab
    await page.getByRole('button', { name: /Cost Ledger Entries/i }).click();
    await expect(page.getByRole('main').getByText(/Cost Ledger Entries/i)).toBeVisible();
  });
});
