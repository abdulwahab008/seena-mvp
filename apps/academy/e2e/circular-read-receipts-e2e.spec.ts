import { test, expect } from '@playwright/test';

test.describe('FR-M13: Circular Read Receipts', () => {
  test('Principal views read receipts stats, inspects open rate, and exports unread segment for campaign follow-up', async ({
    page,
  }) => {
    // 1. Sign in as Owner / Principal
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Circular Publishing Desk
    await page.goto('/communication/circulars');
    await page.waitForLoadState('networkidle');

    // 3. Compose a new published circular to track read receipts
    const composeBtn = page.locator('#compose-circular-btn');
    await expect(composeBtn).toBeVisible();
    await composeBtn.click();

    const timestamp = Date.now();
    const circularTitle = `Sports Day Parent Circular ${timestamp}`;
    await page.locator('#circular-title').fill(circularTitle);
    await page.locator('#body-en').fill('Please find the annual sports day rules and event schedule.');
    await page.locator('#body-ur').fill('سالانہ کھیلوں کے دن کے قواعد و ضوابط ملاحظہ فرمائیں۔');

    // Submit and Publish Circular
    const submitBtn = page.locator('#submit-circular-btn');
    await submitBtn.click();
    await expect(page.getByText(/successfully published/i)).toBeVisible({ timeout: 10000 });

    // 4. Locate the newly published circular in the desk table
    const circularRow = page.locator('tr', { hasText: circularTitle });
    await expect(circularRow).toBeVisible();
    await expect(circularRow.getByText('published')).toBeVisible();

    // Verify Read Stats column exists and shows formatted stats (AC 2)
    await expect(circularRow.getByText(/read \(/i)).toBeVisible();

    // 5. Open Stats Modal
    const viewStatsBtn = circularRow.getByRole('button', { name: 'View Stats' });
    await expect(viewStatsBtn).toBeVisible();
    await viewStatsBtn.click();

    // Verify modal is open
    const statsModal = page.locator('#circular-stats-modal');
    await expect(statsModal).toBeVisible();
    await expect(statsModal.getByText('Read Receipts & Stats')).toBeVisible();
    await expect(statsModal.getByText(circularTitle)).toBeVisible();

    // 6. Verify Stat Cards (Targeted, Read, Unread, Open Rate)
    const totalTargeted = page.locator('#stat-total-targeted');
    await expect(totalTargeted).toBeVisible();

    const readCount = page.locator('#stat-read-count');
    await expect(readCount).toBeVisible();

    const unreadCount = page.locator('#stat-unread-count');
    await expect(unreadCount).toBeVisible();

    const openRate = page.locator('#stat-open-rate');
    await expect(openRate).toBeVisible();

    const formattedSummary = page.locator('#stat-formatted-summary');
    await expect(formattedSummary).toBeVisible();
    await expect(formattedSummary).toContainText(/read \(/i);

    // 7. AC 2: Test Export Unread Segment for FR-M06 follow-up
    const exportInput = page.locator('#export-segment-name-input');
    await expect(exportInput).toBeVisible();
    const defaultExportName = await exportInput.inputValue();
    expect(defaultExportName).toContain(circularTitle);

    const exportBtn = page.locator('#btn-confirm-export-unread');
    await expect(exportBtn).toBeVisible();

    // Check if there are unread guardians to export
    const unreadCountVal = parseInt(await unreadCount.innerText(), 10);
    if (unreadCountVal > 0) {
      await exportBtn.click();
      const feedbackMsg = page.locator('#export-feedback-message');
      await expect(feedbackMsg).toBeVisible({ timeout: 8000 });
      await expect(feedbackMsg).toContainText(/created successfully/i);
    }

    // 8. Close the Stats Modal
    await statsModal.getByRole('button', { name: 'Close' }).click();
    await expect(statsModal).toBeHidden();

    // 9. Navigate to Portal Circulars and verify parent view
    await page.goto('/portal/circulars');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h2')).toContainText('Official School Circulars');
  });
});
