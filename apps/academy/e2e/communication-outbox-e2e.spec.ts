import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test.describe('FR-M01: Unified Outbound Message Outbox End-to-End Flow', () => {
  test('Principal / Owner can view outbox, compose a message, claim batch, and inspect attempts', async ({ page }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('comm-outbox');
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Message Outbox
    await page.goto('/communication/outbox');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Header and Metrics
    await expect(page.locator('h1')).toContainText('Unified Outbound Message Outbox');
    await expect(page.getByText('FR-M01:')).toBeVisible();
    await expect(page.getByText('Queued', { exact: true })).toBeVisible();
    await expect(page.getByText('Delivered', { exact: true })).toBeVisible();

    // 4. Compose a new outbound notification
    await page.getByRole('button', { name: 'New Message' }).click();
    await expect(page.getByText('Compose Outbound Message')).toBeVisible();

    const uniquePhone = `+92300${Math.floor(1000000 + Math.random() * 9000000)}`;
    const testBody = `Notice: Annual sports meet timings updated for tomorrow. Ref: ${Date.now()}`;

    await page.getByPlaceholder('+923001234567').fill(uniquePhone);
    await page.getByPlaceholder('Enter message body or notification text...').fill(testBody);
    await page.getByRole('button', { name: 'Queue Message' }).click();

    // 5. Verify the newly queued message appears in the outbox table
    await expect(page.getByText(uniquePhone)).toBeVisible({ timeout: 10000 });
    await expect(page.getByText(testBody)).toBeVisible();

    // 6. Test Batch Dispatch Worker Action
    const dispatchBtn = page.getByRole('button', { name: /Claim & Dispatch Batch/i });
    await expect(dispatchBtn).toBeVisible();
    await dispatchBtn.click();
    await page.waitForLoadState('networkidle');

    // 7. Inspect the message details
    const inspectBtn = page.locator('tr', { hasText: uniquePhone }).getByRole('button', { name: 'Inspect' });
    await expect(inspectBtn).toBeVisible();
    await inspectBtn.click();

    // 8. Verify the inspection modal displays the message details and recipient
    await expect(page.getByText('Message Outbox Details')).toBeVisible();
    await expect(page.getByText(/Dispatch Attempts \(\d+\)/)).toBeVisible();
  });
});
