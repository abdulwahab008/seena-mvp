import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test.describe('FR-M14: Campus Events Calendar', () => {
  test('Principal manages events, creates campus override (AC 2), tests .ics feed token & 401 revocation (AC 3), and views portal calendar', async ({
    page,
    request,
  }) => {
    // 1. Sign in as Owner / Principal
    const owner = await seedSchoolOwner('campus-events');
    // The owner previews the guardian .ics feed against the school's first guardian.
    const { error: guardianError } = await owner.admin
      .from('guardian')
      .insert({ tenant_id: owner.tenantId, name_en: 'Calendar Parent', phone_e164: '+923001230014' });
    if (guardianError) throw guardianError;
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Campus Events Calendar Desk
    await page.goto('/communication/calendar');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Campus Events & Calendar');

    // 3. Create a new event
    const createBtn = page.locator('#btn-create-event');
    await expect(createBtn).toBeVisible();
    await createBtn.click();

    const timestamp = Date.now();
    const eventTitle = `Centralized Sports Festival ${timestamp}`;
    await page.locator('#event-title').fill(eventTitle);
    await page.locator('#event-type').selectOption('sports');

    // Set future dates (tomorrow)
    const tomorrow = new Date(Date.now() + 86400000);
    const tomorrowStr = tomorrow.toISOString().slice(0, 16);
    const nextDay = new Date(Date.now() + 2 * 86400000);
    const nextDayStr = nextDay.toISOString().slice(0, 16);

    await page.locator('#event-starts-at').fill(tomorrowStr);
    await page.locator('#event-ends-at').fill(nextDayStr);
    await page.locator('#event-desc').fill('Inter-campus sports competition.');

    await page.locator('#btn-save-event').click();
    await expect(page.getByText(/saved successfully/i)).toBeVisible({ timeout: 8000 });

    // 4. Verify event in table (tenant-wide event resolves across all campuses)
    const eventRow = page.locator('tr', { hasText: eventTitle }).first();
    await expect(eventRow).toBeVisible();
    await expect(eventRow.getByText('sports', { exact: true })).toBeVisible();

    // 5. Test AC 2: Campus Override
    const overrideBtn = eventRow.getByRole('button', { name: 'Override' });
    await expect(overrideBtn).toBeVisible();
    await overrideBtn.click();

    await expect(page.getByText(/Override Event for Campus/i)).toBeVisible();
    await page.locator('#override-title').fill(`Overridden ${eventTitle}`);
    await page.locator('#override-reason').fill('Weather delay override');
    await page.locator('#btn-save-override').click();

    await expect(page.getByText(/Campus override saved/i)).toBeVisible({ timeout: 8000 });

    // 6. Test AC 3: iCal Feed Token and 401 upon Revocation
    const feedBtn = page.locator('#btn-calendar-feed');
    await expect(feedBtn).toBeVisible();
    await feedBtn.click();

    const icsModal = page.locator('#ics-feed-modal');
    await expect(icsModal).toBeVisible();
    await expect(icsModal.getByText('Guardian iCalendar Feed (.ics)')).toBeVisible();

    const urlInput = page.locator('#ics-url-input');
    await expect(urlInput).toBeVisible({ timeout: 6000 });
    const feedUrl = await urlInput.inputValue();
    expect(feedUrl).toContain('/api/calendar/feed/');

    // Test feed endpoint returns valid iCalendar (200 OK)
    const feedResponse = await request.get(feedUrl);
    expect(feedResponse.status()).toBe(200);
    const icsText = await feedResponse.text();
    expect(icsText).toContain('BEGIN:VCALENDAR');
    expect(icsText).toContain('VERSION:2.0');

    // Revoke the token
    const revokeBtn = page.locator('#btn-revoke-feed');
    await expect(revokeBtn).toBeVisible();
    await revokeBtn.click();

    await expect(page.getByText(/Token revoked/i)).toBeVisible({ timeout: 6000 });

    // Test that the revoked URL now returns 401 Unauthorized (AC 3)
    const revokedResponse = await request.get(feedUrl);
    expect(revokedResponse.status()).toBe(401);

    // Close iCal modal
    await icsModal.getByRole('button', { name: 'Close' }).click();
    await expect(icsModal).toBeHidden();

    // 7. Verify Parent Portal Calendar Page
    await page.goto('/portal/calendar');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h2')).toContainText('Campus Events & Holidays Calendar');
  });
});
