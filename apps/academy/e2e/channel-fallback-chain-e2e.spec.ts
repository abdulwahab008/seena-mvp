import { test, expect } from '@playwright/test';

test.describe('FR-M02: Channel Fallback Chains End-to-End Flow', () => {
  test('Principal / Owner can configure fallback rules, manage opt-outs, and review multi-hop audit', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Channel Fallback Chains
    await page.goto('/communication/fallback-chains');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Header and Badges
    await expect(page.locator('h1')).toContainText('Channel Fallback Chains');
    await expect(page.getByText('FR-M02')).toBeVisible();

    // 4. Verify default fallback chains exist
    await expect(page.getByText('default', { exact: true }).first()).toBeVisible();

    // 5. Open Configure Chain Modal
    await page.getByRole('button', { name: 'Configure Chain' }).click();
    await expect(page.getByText('Configure Channel Fallback Chain')).toBeVisible();

    const uniqueClass = `exam_alert_${Date.now()}`;
    await page.getByPlaceholder('e.g. emergency, fee, attendance, general').fill(uniqueClass);
    await page.getByPlaceholder('e.g. Critical notification with fast SMS fallback').fill('Exam emergency alert chain');

    // Save fallback chain
    await page.getByRole('button', { name: 'Save Fallback Chain' }).click();

    // Verify new chain appears
    await expect(page.getByText(uniqueClass).first()).toBeVisible({ timeout: 10000 });

    // 6. Test Opt-Out Suppression Workflow
    const uniquePhone = `+92300${Math.floor(1000000 + Math.random() * 9000000)}`;
    await page.getByRole('button', { name: 'Capture Opt-Out' }).click();
    await expect(page.getByText('Capture Channel Opt-Out')).toBeVisible();

    await page.getByPlaceholder('+923001234567').fill(uniquePhone);
    await page.getByRole('button', { name: 'Record Opt-Out' }).click();

    // Switch to Opt-Outs Tab
    await page.getByRole('button', { name: /Opt-Out Suppression/i }).click();
    await expect(page.getByText(uniquePhone)).toBeVisible({ timeout: 10000 });

    // Unblock the suppression
    const optOutRow = page.locator('tr', { hasText: uniquePhone });
    await optOutRow.getByRole('button', { name: /Unblock/i }).click();
    await expect(page.getByText(uniquePhone)).not.toBeVisible({ timeout: 10000 });

    // 7. Test Webhook Simulator Tab
    await page.getByRole('button', { name: /Webhook & Receipt Simulator/i }).click();
    await expect(page.getByText('Aggregator Delivery Webhook Simulator')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Dispatch Simulated Webhook Receipt' })).toBeVisible();

    // 8. Test Escalations & Cost Ledger Tab
    await page.getByRole('button', { name: /Escalations & Cost Ledger/i }).click();
    await expect(page.getByText('Fallback Routing Log & Multi-Hop Audit')).toBeVisible();
  });
});
