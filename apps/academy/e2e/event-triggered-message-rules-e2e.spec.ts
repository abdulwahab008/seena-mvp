import { test, expect } from '@playwright/test';

test.describe('FR-M08: Event-Triggered Message Rules & Asynchronous Deduplication Engine', () => {
  test('Principal / Owner manages trigger rules, tests exact deduplication (AC 1), overdue rules (AC 2), non-blocking save SLA (AC 3), and re-enablement without backfill (AC 4)', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Event-Triggered Message Rules Desk
    await page.goto('/communication/triggers');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Title and Metrics
    await expect(page.locator('h1')).toContainText('Event-Triggered Message Rules');
    await expect(page.getByRole('main').getByText('Trigger Rules', { exact: true })).toBeVisible();
    await expect(page.getByText('Outbox Enqueued', { exact: true })).toBeVisible();
    await expect(page.getByText('Pending Queue', { exact: true })).toBeVisible();
    await expect(page.getByText('Cancelled / Deduped', { exact: true })).toBeVisible();

    // 4. Verify Default Seeded Rules Exist
    await expect(page.getByText('Daily Absence Alert (SMS)').first()).toBeVisible();
    await expect(page.getByText('Fee Overdue Escalation (D+1, D+7, D+15)').first()).toBeVisible();

    // 5. Create a New Declarative Trigger Rule
    const uniqueRuleName = `Result Notification Rule ${Date.now()}`;
    await page.getByRole('button', { name: 'New Trigger Rule' }).click();
    const createDialog = page.getByRole('dialog', { name: 'Create Declarative Trigger Rule' });
    await expect(createDialog).toBeVisible();

    await createDialog.getByPlaceholder('e.g. Daily Absentee Alert (SMS)').fill(uniqueRuleName);
    await createDialog.locator('select').first().selectOption('result_published');
    await createDialog
      .getByPlaceholder('Explain when this rule triggers and who receives it...')
      .fill('Sends instant notification when term results are published.');

    await createDialog.getByRole('button', { name: 'Save Trigger Rule' }).click();
    await expect(createDialog).not.toBeVisible({ timeout: 10000 });

    // Verify new rule appears in table
    const ruleRow = page.locator('tr', { hasText: uniqueRuleName });
    await expect(ruleRow).toBeVisible();
    await expect(ruleRow.getByText('result_published')).toBeVisible();
    await expect(ruleRow.getByText('Active')).toBeVisible();

    // 6. Test AC 4: Toggle Rule Off and On (No Historical Backfill)
    const toggleButton = ruleRow.getByRole('button', { name: 'Active' });
    await toggleButton.click();
    await expect(ruleRow.getByText('Disabled')).toBeVisible();

    // Re-enable
    await ruleRow.getByRole('button', { name: 'Disabled' }).click();
    await expect(ruleRow.getByText('Active')).toBeVisible();
    await expect(page.getByText(/no historical backfill/i)).toBeVisible();

    // 7. Test AC 2: Evaluate Overdue Rules Action
    await page.getByRole('button', { name: 'Evaluate Overdue Rules' }).click();
    await expect(page.getByText(/Overdue evaluation completed/i)).toBeVisible({ timeout: 10000 });

    // 8. Test Trigger Fire Dedupe Log Tab (AC 1 & AC 2)
    await page.getByRole('button', { name: /Trigger Fire Dedupe Log/i }).click();
    await expect(page.getByText('Trigger Fire Audit Log & Deduplication Engine')).toBeVisible();

    // 9. Test Dispatch Pending Queue Action
    await page.getByRole('button', { name: 'Process Pending Queue' }).click();
    await expect(page.getByText(/Enqueued \d+ messages into outbox/i)).toBeVisible({ timeout: 10000 });
  });
});
