import { test, expect } from '@playwright/test';

test.describe('FR-M07: Scheduled Sends with Quiet Hours & PTA Anti-Spam Compliance', () => {
  test('Principal / Owner schedules campaigns, validates past-time rejection (AC 3), tests quiet hours deferral (AC 1), executes emergency bypass with audit log (AC 2), and creates Ramadan override (AC 4)', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Scheduled Sends Desk
    await page.goto('/communication/scheduled');
    await page.waitForLoadState('networkidle');

    // 3. Verify Header and Policy Metric Cards
    await expect(page.locator('h1')).toContainText('Scheduled Sends & Quiet Hours');
    await expect(page.getByText('PTA Quiet Policy')).toBeVisible();
    await expect(page.getByText('Scheduled Queue')).toBeVisible();
    await expect(page.getByText('Seasonal Overrides', { exact: true })).toBeVisible();
    await expect(page.getByText('Emergency Bypasses')).toBeVisible();

    // 4. Verify Default Policy Window (21:00 to 08:00 PKT)
    await expect(page.getByText('21:00 – 08:00 PKT')).toBeVisible();

    // ─── 5. Test AC 3: Validation Error on Past Timestamp ─────────────────
    await page.getByRole('button', { name: 'Schedule Campaign' }).click();
    const scheduleDialog = page.getByRole('dialog', { name: 'Schedule Message Campaign' });
    await expect(scheduleDialog).toBeVisible();

    await scheduleDialog.getByPlaceholder('e.g. End of Term Parent Briefing').fill('Past Test Notice');
    await scheduleDialog.getByPlaceholder('Enter message content...').fill('This should never send.');

    // Helper to format local datetime string for input[type="datetime-local"]
    const formatLocalDatetime = (d: Date): string => {
      const pad = (n: number) => String(n).padStart(2, '0');
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
    };

    // Set time to yesterday
    const pastDate = new Date(Date.now() - 24 * 60 * 60 * 1000);
    await scheduleDialog.locator('input[type="datetime-local"]').fill(formatLocalDatetime(pastDate));

    // Verify dynamic warning banner for past timestamp (AC 3)
    await expect(scheduleDialog.getByText('Scheduled time cannot be in the past')).toBeVisible();

    // Attempt submit and verify error validation prevents past send
    await scheduleDialog.getByRole('button', { name: 'Save & Register Campaign' }).click();
    await expect(
      scheduleDialog.getByText(/Validation Error: Scheduled time cannot be in the past/i)
    ).toBeVisible();

    // ─── 6. Test AC 1: Scheduled for 22:30 PKT Deferred to 08:00 Morning ─
    const deferredCampaignTitle = `Quiet Hours Parent Newsletter ${Date.now()}`;
    await scheduleDialog.getByPlaceholder('e.g. End of Term Parent Briefing').fill(deferredCampaignTitle);
    await scheduleDialog.getByPlaceholder('Enter message content...').fill('Quarterly exam syllabus and fee updates.');

    // Compute future date at 22:30 PKT (quiet hours)
    const futureDate = new Date();
    futureDate.setDate(futureDate.getDate() + 2);
    futureDate.setHours(22, 30, 0, 0);
    await scheduleDialog.locator('input[type="datetime-local"]').fill(formatLocalDatetime(futureDate));

    // Advisory banner should indicate Quiet Hours detection
    await expect(scheduleDialog.getByText(/Quiet Hours Detected/i)).toBeVisible();

    // Submit normal (non-emergency) campaign
    await scheduleDialog.getByRole('button', { name: 'Save & Register Campaign' }).click();

    // Dialog closes and campaign appears with Deferred Quiet Hours status (AC 1)
    await expect(scheduleDialog).not.toBeVisible({ timeout: 10000 });
    const deferredRow = page.locator('tr', { hasText: deferredCampaignTitle });
    await expect(deferredRow).toBeVisible();
    await expect(deferredRow.getByText('Deferred Quiet Hours')).toBeVisible();
    await expect(deferredRow.locator('td').nth(5)).not.toHaveText('—');

    // ─── 7. Test AC 2: Emergency School Closure Bypass at 23:10 PKT ──────
    await page.getByRole('button', { name: 'Schedule Campaign' }).click();
    await expect(scheduleDialog).toBeVisible();

    const emergencyTitle = `EMERGENCY: Flood Closure Alert ${Date.now()}`;
    await scheduleDialog.getByPlaceholder('e.g. End of Term Parent Briefing').fill(emergencyTitle);
    await scheduleDialog.getByPlaceholder('Enter message content...').fill(
      'School will remain closed tomorrow due to heavy rainfall and flood advisory issued by District Administration.'
    );

    // Set time to tomorrow at 23:10 PKT (deep quiet hours)
    const emergencyDate = new Date();
    emergencyDate.setDate(emergencyDate.getDate() + 1);
    emergencyDate.setHours(23, 10, 0, 0);
    await scheduleDialog.locator('input[type="datetime-local"]').fill(formatLocalDatetime(emergencyDate));

    // Toggle Emergency Bypass Checkbox
    await scheduleDialog.getByLabel(/Emergency Bypass/i).check();

    // Verify required Emergency Reason field appears
    const reasonTextarea = scheduleDialog.getByPlaceholder(/Flash flood warning issued by DC/i);
    await expect(reasonTextarea).toBeVisible();
    const bypassReasonText = 'Severe rainfall and urban flooding alert issued by Provincial Disaster Management Authority';
    await reasonTextarea.fill(bypassReasonText);

    // Save Campaign
    await scheduleDialog.getByRole('button', { name: 'Save & Register Campaign' }).click();
    await expect(scheduleDialog).not.toBeVisible({ timeout: 10000 });

    // Verify campaign row indicates Emergency and Dispatched/Dispatching status (AC 2)
    const emergencyRow = page.locator('tr', { hasText: emergencyTitle });
    await expect(emergencyRow).toBeVisible();
    await expect(emergencyRow.getByText('Emergency', { exact: true })).toBeVisible();

    // Switch to Emergency Bypass Audit Log Tab and verify immutable entry (AC 2)
    await page.getByRole('button', { name: /Emergency Bypass Audit Log/i }).click();
    await expect(page.getByText('Quiet Hours Emergency Bypass Audit Log (PTA Section 7)')).toBeVisible();
    const logRow = page.locator('tr', { hasText: emergencyTitle });
    await expect(logRow).toBeVisible();
    await expect(logRow.getByText(bypassReasonText)).toBeVisible();
    await expect(logRow.getByText('PTA Compliant Audit Entry')).toBeVisible();

    // ─── 8. Test AC 4: Ramadan Seasonal Quiet Window Override ─────────────
    await page.getByRole('button', { name: /Ramadan \/ Seasonal Overrides/i }).click();
    await expect(page.getByText('Seasonal & Ramadan Quiet Windows (AC 4)')).toBeVisible();

    await page.getByRole('button', { name: 'Add Seasonal Override' }).click();
    const overrideDialog = page.getByRole('dialog', { name: /Create Seasonal \/ Ramadan Override/i });
    await expect(overrideDialog).toBeVisible();

    const overrideNameVal = `Ramadan 2026 Night Window ${Date.now()}`;
    await overrideDialog.getByPlaceholder(/Ramadan 2026 Night Schedule/i).fill(overrideNameVal);

    // Set date range (e.g. 2026-10-01 to 2026-10-30)
    await overrideDialog.locator('input[type="date"]').first().fill('2026-10-01');
    await overrideDialog.locator('input[type="date"]').nth(1).fill('2026-10-30');

    // Quiet start 23:30, quiet end 09:00
    await overrideDialog.locator('input[type="time"]').first().fill('23:30');
    await overrideDialog.locator('input[type="time"]').nth(1).fill('09:00');

    await overrideDialog.getByRole('button', { name: 'Save Override' }).click();
    await expect(overrideDialog).not.toBeVisible({ timeout: 10000 });

    // Verify override card appears in list (AC 4)
    const overrideCard = page.locator('.rounded-xl', { hasText: 'Date Range:' }).filter({ hasText: overrideNameVal });
    await expect(overrideCard).toBeVisible();
    await expect(overrideCard.getByText('23:30 to 09:00 PKT')).toBeVisible();

    // ─── 9. Test Dispatcher Evaluation Trigger ────────────────────────────
    await page.getByRole('button', { name: /^Campaigns \(/ }).click();
    await page.getByRole('button', { name: 'Evaluate Dispatcher' }).click();
    await expect(page.getByText(/Dispatcher evaluated successfully/i)).toBeVisible({ timeout: 10000 });
  });
});
