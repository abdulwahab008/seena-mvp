import { test, expect } from '@playwright/test';

test.describe('Universal DatePicker Functionality & UI Consistency Across Modules', () => {
  test('Owner can interact with calendar popovers, year/month selectors, and Today shortcuts across modules', async ({ page }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    // 2. Test DatePicker in Fees Collection Reports (/fees/reports)
    await page.goto('/fees/reports');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Daily collection report');

    const reportFrom = page.getByTestId('report-from-input');
    const reportTo = page.getByTestId('report-to-input');
    await expect(reportFrom).toBeVisible();
    await expect(reportTo).toBeVisible();

    // Click calendar toggle icon on report-from
    const fromCalendarBtn = reportFrom.locator('..').getByRole('button', { name: 'Toggle calendar date picker' });
    await fromCalendarBtn.click();

    // Verify calendar popover is open
    const fromPopover = page.getByTestId('report-from-input-popover');
    await expect(fromPopover).toBeVisible();
    await expect(fromPopover.getByRole('button', { name: 'Today' })).toBeVisible();

    // Click "Today" button and verify date filled
    await fromPopover.getByRole('button', { name: 'Today' }).click();
    await expect(fromPopover).not.toBeVisible();
    const todayStr = new Date().toISOString().slice(0, 10);
    await expect(reportFrom).toHaveValue(todayStr);

    // 3. Test DatePicker in Audit Export (/audit-export)
    await page.goto('/audit-export');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Audit trail export');

    const exportFrom = page.getByTestId('export-from-input');
    const exportTo = page.getByTestId('export-to-input');
    await expect(exportFrom).toBeVisible();
    await expect(exportTo).toBeVisible();

    // Click on input directly to open calendar
    await exportTo.click();
    const toPopover = page.getByTestId('export-to-input-popover');
    await expect(toPopover).toBeVisible();

    // Select day 15 from popover
    await toPopover.getByRole('button', { name: '15', exact: true }).first().click();
    await expect(toPopover).not.toBeVisible();
    const exportToVal = await exportTo.inputValue();
    expect(exportToVal).toMatch(/^\d{4}-\d{2}-15$/);

    // Test clear button
    const clearBtn = exportTo.locator('..').getByRole('button', { name: 'Clear date' });
    await expect(clearBtn).toBeVisible();
    await clearBtn.click();
    await expect(exportTo).toHaveValue('');

    // 4. Test DatePicker in Attendance Register (/attendance/register)
    await page.goto('/attendance/register');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Attendance Register');

    const registerDate = page.getByTestId('register-date');
    await expect(registerDate).toBeVisible();
    // Default attendance date should be today
    await expect(registerDate).toHaveValue(todayStr);

    // Open calendar popover and verify month/year jump selects
    const regCalendarBtn = registerDate.locator('..').getByRole('button', { name: 'Toggle calendar date picker' });
    await regCalendarBtn.click();
    const regPopover = page.getByTestId('register-date-popover');
    await expect(regPopover).toBeVisible();
    await expect(regPopover.locator('select')).toHaveCount(2); // Month and Year selects

    // 5. Test DatePicker in Academic Sessions (/sessions)
    await page.goto('/sessions');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Academic Sessions');

    const sessionStarts = page.getByTestId('session-starts');
    const sessionEnds = page.getByTestId('session-ends');
    await expect(sessionStarts).toBeVisible();
    await expect(sessionEnds).toBeVisible();

    // Type date directly or programmatic fill works flawlessly
    await sessionStarts.fill('2026-08-01');
    await expect(sessionStarts).toHaveValue('2026-08-01');
    await sessionEnds.fill('2027-06-30');
    await expect(sessionEnds).toHaveValue('2027-06-30');
  });
});
