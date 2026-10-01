import { test, expect } from '@playwright/test';
import { seedSchoolOwner, seedDefaultSegments } from './support/school-owner-seed';

test.describe('FR-M06: Dynamic Audience Segments & Immutable Snapshot Engine', () => {
  test('Principal / Owner manages dynamic segments, tests sub-2s query SLA, configures attendance cutoff guard, and verifies zero-recipient send guard', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('audience-segments');
    // The default segments are only backfilled for campuses that existed when the migration ran.
    await seedDefaultSegments(owner);
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Dynamic Audience Segments Desk
    await page.goto('/communication/segments');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Title and Metrics
    await expect(page.locator('h1')).toContainText('Dynamic Audience Segments');
    await expect(page.getByText('Total Segments')).toBeVisible();
    await expect(page.getByText('Defaulter Rules')).toBeVisible();
    await expect(page.getByText('Absentee Rules')).toBeVisible();
    await expect(page.getByText('Audience Snapshots')).toBeVisible();

    // 4. Verify Default Seed Segments Exist
    await expect(page.getByRole('heading', { name: 'Fee Defaulters (> PKR 5,000)' }).first()).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Unexcused Absentees Today' }).first()).toBeVisible();

    // 5. Create a New Dynamic Defaulters Segment (AC 1)
    const uniqueSegmentName = `Matric Defaulters Alert ${Date.now()}`;
    await page.getByRole('button', { name: 'New Segment' }).click();
    await expect(page.getByRole('heading', { name: 'Create Dynamic Segment' })).toBeVisible();

    await page.getByPlaceholder('e.g. Fee Defaulters (> PKR 5,000)').fill(uniqueSegmentName);
    await page
      .getByPlaceholder('Explain the audience criteria and communication purpose...')
      .fill('Target matric students with unpaid arrears > PKR 10,000, excluding approved hardship aid.');

    // Adjust minimum dues
    const duesInput = page.locator('input[type="number"]');
    await duesInput.fill('10000');

    // Verify hardship exclusion checkbox is checked by default
    const hardshipCheckbox = page.locator('#chk-hardship');
    await expect(hardshipCheckbox).toBeChecked();

    await page.getByRole('button', { name: 'Create Segment' }).click();

    // Verify segment appears in list
    const newCard = page.locator('.rounded-lg', { hasText: uniqueSegmentName });
    await expect(newCard).toBeVisible({ timeout: 15000 });
    await expect(newCard.getByText('defaulters', { exact: true })).toBeVisible();
    await expect(newCard.locator('span', { hasText: '> PKR 10,000' })).toBeVisible();

    // 6. Test Real-time Resolution & Sub-2s SLA (AC 1)
    await newCard.getByRole('button', { name: 'Preview' }).click();
    await expect(page.getByText(`Live Audience Preview: ${uniqueSegmentName}`)).toBeVisible();

    // SLA timing badge should be visible and indicate sub-2s SLA met
    await expect(page.getByText(/Sub-2s SLA Met/i)).toBeVisible({ timeout: 10000 });
    await page.getByRole('dialog').getByLabel('Close').click();

    // 7. Test Attendance Cutoff Guard Configuration (AC 2)
    await page.getByRole('button', { name: /Attendance Cutoff Guard/i }).click();
    await expect(page.getByText('Campus Attendance-Lock Cutoff')).toBeVisible();

    // Save cutoff time
    await page.getByRole('button', { name: 'Save Cutoff Time' }).click();
    await expect(page.getByText('Attendance lock cutoff saved successfully.')).toBeVisible();

    // 8. Test Zero-Recipient Send Guard (AC 3)
    // Create an impossible high-dues segment that resolves to 0 recipients
    await page.getByRole('button', { name: /Active Segments/i }).click();
    const zeroSegmentName = `Zero Dues Test ${Date.now()}`;
    await page.getByRole('button', { name: 'New Segment' }).click();
    await expect(page.getByRole('heading', { name: 'Create Dynamic Segment' })).toBeVisible();
    await page.getByRole('dialog').getByPlaceholder('e.g. Fee Defaulters (> PKR 5,000)').fill(zeroSegmentName);
    await page.getByRole('dialog').locator('input[type="number"]').fill('100000000');
    await page.getByRole('dialog').getByRole('button', { name: 'Create Segment' }).click();
    await expect(page.getByRole('heading', { name: 'Create Dynamic Segment' })).not.toBeVisible({ timeout: 10000 });

    const zeroCard = page.locator('.rounded-lg', { hasText: zeroSegmentName });
    await expect(zeroCard).toBeVisible({ timeout: 15000 });

    // Open Send modal
    await zeroCard.getByRole('button', { name: 'Send' }).click();
    await expect(page.getByRole('heading', { name: 'Dispatch Dynamic Campaign' })).toBeVisible();

    // Attempt dispatch
    await page.getByRole('button', { name: 'Dispatch & Snapshot' }).click();

    // Assert Zero-Recipient Guard blocked dispatch with explicit warning
    await expect(page.getByText('Dispatch Blocked (FR-M06 Zero-Recipient Guard)')).toBeVisible();
    await expect(page.getByText(/resolved to 0 recipients/i)).toBeVisible();
    await page.getByRole('button', { name: 'Cancel' }).click();

    // 9. Verify Audience Audit Trail Tab (AC 4)
    await page.getByRole('button', { name: /Audience Audit Trail/i }).click();
    await expect(page.getByText('FR-M06 Point-in-Time Immutable Audience Snapshots')).toBeVisible();
    await expect(page.locator('table thead')).toContainText('Campaign ID');
    await expect(page.locator('table thead')).toContainText('Student');
    await expect(page.locator('table thead')).toContainText('Primary Guardian');
    await expect(page.locator('table thead')).toContainText('Snapshotted At');
  });
});
