import { test, expect } from '@playwright/test';

test.describe('FR-M05: WhatsApp Session Window Enforcement & Meta Compliance', () => {
  test('Principal / Owner manages 24h windows, Meta templates, Principal alerts, and triggers SMS fallback', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to WhatsApp Compliance Desk
    await page.goto('/communication/whatsapp');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Header and Badges
    await expect(page.locator('h1')).toContainText('WhatsApp Compliance Desk');
    await expect(page.getByText('Meta 24h Enforced')).toBeVisible();

    // 4. Verify Metric Cards
    await expect(page.getByText('Active 24h Windows')).toBeVisible();
    await expect(page.getByText('Approved Templates')).toBeVisible();
    await expect(page.getByText('Pending / Under Review')).toBeVisible();
    await expect(page.getByText('Principal Alerts')).toBeVisible();

    // 5. Simulate Inbound Parent Message (opens 24h window)
    const uniquePhone = `+92300${Math.floor(1000000 + Math.random() * 9000000)}`;
    await page.getByRole('button', { name: 'Simulate Inbound Message' }).first().click();
    await expect(page.getByText('Simulate WhatsApp Inbound Message')).toBeVisible();

    await page.getByPlaceholder('+923001234567').fill(uniquePhone);
    await page.getByPlaceholder('Type simulated message...').fill('Salam, when will exams begin?');
    await page.getByRole('button', { name: 'Simulate & Open 24h Window' }).click();

    // Verify row appears in Active 24h Windows
    const row = page.locator('tr', { hasText: uniquePhone });
    await expect(row).toBeVisible({ timeout: 15000 });
    await expect(row.getByText('Active 24h Window')).toBeVisible();

    // 6. Test Meta Template Whitelist & Registration
    await page.getByRole('button', { name: /Meta Template Whitelist/i }).click();
    await expect(page.getByRole('button', { name: 'Register New Meta Template' })).toBeVisible();

    const uniqueTemplateName = `challan_notice_${Date.now()}`;
    await page.getByRole('button', { name: 'Register New Meta Template' }).click();
    await expect(page.getByRole('heading', { name: 'Register New Meta Template' })).toBeVisible();

    await page.getByPlaceholder('exam_dates_v1').fill(uniqueTemplateName);
    await page.getByPlaceholder('Dear Parent, exams for {{1}} begin on {{2}}.').fill(
      'Dear Parent, fee challan for {{1}} is generated. Due date {{2}}.'
    );
    await page.getByRole('dialog').getByRole('button', { name: 'Register Meta Template' }).click();

    // Verify new template appears with PENDING badge
    const templateCard = page.locator('.rounded-lg', { hasText: uniqueTemplateName });
    await expect(templateCard).toBeVisible({ timeout: 15000 });
    await expect(templateCard.getByText('PENDING', { exact: true })).toBeVisible();

    // 7. Simulate Meta Status Sync: First approve the template
    await templateCard.getByRole('button', { name: 'Simulate Meta Status Sync' }).click();
    await expect(page.getByRole('heading', { name: 'Simulate Meta Status Sync' })).toBeVisible();
    await page.getByLabel('Meta Review Status').selectOption('APPROVED');
    await page.getByRole('button', { name: 'Update Meta Status' }).click();
    await expect(templateCard.getByText('APPROVED', { exact: true })).toBeVisible({ timeout: 15000 });

    // 7b. Now simulate Meta invalidating the approved template (triggers auto-pause & Principal alert)
    await templateCard.getByRole('button', { name: 'Simulate Meta Status Sync' }).click();
    await expect(page.getByRole('heading', { name: 'Simulate Meta Status Sync' })).toBeVisible();
    await page.getByLabel('Meta Review Status').selectOption('REJECTED');
    await page.getByPlaceholder('Violates Meta Commerce Policy section 4.3').fill('Contains unauthorized promotional language');
    await page.getByRole('button', { name: 'Update Meta Status' }).click();

    // Verify card updates to REJECTED with rejection diagnostic
    await expect(templateCard.getByText('REJECTED', { exact: true })).toBeVisible({ timeout: 15000 });
    await expect(templateCard.getByText('Contains unauthorized promotional language')).toBeVisible();

    // 8. Verify Compliance Alerts Tab
    await page.getByRole('button', { name: /Compliance Alerts/i }).click();
    await expect(page.getByText(new RegExp(`WhatsApp Template ${uniqueTemplateName} was REJECTED`, 'i'))).toBeVisible({
      timeout: 10000,
    });

    // 9. Test Dispatch & Fallback Simulator Tab
    await page.getByRole('button', { name: /Dispatch & Fallback Simulator/i }).click();
    await expect(page.getByText('WhatsApp Dispatch & 24h Window Tester')).toBeVisible();

    // 9a. Test Freeform message to unengaged recipient (Window closed -> WA_WINDOW_CLOSED -> Fallback to SMS)
    const unengagedPhone = `+92311${Math.floor(1000000 + Math.random() * 9000000)}`;
    await page.getByTestId('sim-phone-input').fill(unengagedPhone);
    await page.getByRole('button', { name: 'Free-form Content' }).click();
    await page.getByRole('button', { name: 'Simulate Dispatch & Evaluate Rules' }).click();

    // Verify rejection and SMS fallback
    await expect(page.getByText('Dispatch Blocked: WA_WINDOW_CLOSED')).toBeVisible({ timeout: 15000 });
    await expect(page.getByText('[WA_WINDOW_CLOSED]')).toBeVisible();
    await expect(page.getByText('Fallback Delivered')).toBeVisible();

    // 9b. Test Freeform message to active session phone (Window open -> Valid)
    await page.getByTestId('sim-phone-input').fill(uniquePhone);
    await page.getByRole('button', { name: 'Simulate Dispatch & Evaluate Rules' }).click();
    await expect(page.getByText('Dispatch Validation Passed')).toBeVisible({ timeout: 15000 });
    await expect(page.getByText('24-hour customer service window is open')).toBeVisible();

    // 9c. Test Template-backed message to unengaged recipient with approved template (Approved -> Valid without window)
    await page.getByRole('button', { name: 'Meta Approved Template' }).click();
    await page.getByRole('button', { name: 'Simulate Dispatch & Evaluate Rules' }).click();
    await expect(page.getByText('Dispatch Validation Passed')).toBeVisible({ timeout: 15000 });
  });
});
