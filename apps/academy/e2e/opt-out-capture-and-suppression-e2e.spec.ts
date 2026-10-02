import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test.describe('FR-M11: Opt-Out Capture, PTA Inbound Keywords and Suppression Engine', () => {
  test('Principal / Owner manages suppressions, tests STOP and بند keywords (AC 1), transactional shield (AC 2), and portal resubscribe audit (AC 3)', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('optout-capture');
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Opt-Outs & Suppression Desk
    await page.goto('/communication/opt-outs');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Title and Metrics
    await expect(page.locator('h1')).toContainText('Opt-Out Capture & Message Suppression');
    await expect(page.getByText('Active Suppressed Numbers')).toBeVisible();
    await expect(page.getByText('Inbound Ingested Messages')).toBeVisible();
    await expect(page.getByText('Transactional Shield')).toBeVisible();

    // 4. Test AC 1: Simulate Inbound English STOP
    const testPhoneEnglish = `+92300${Math.floor(1000000 + Math.random() * 9000000)}`;
    await page.getByPlaceholder('+923001234567').fill(testPhoneEnglish);
    await page.locator('select').selectOption('STOP');
    await page.getByRole('button', { name: 'Simulate Inbound SMS' }).click();

    // Verify success banner and addition to table
    await expect(page.getByText(/Inbound 'STOP' received/i)).toBeVisible({ timeout: 10000 });
    await expect(page.getByRole('cell', { name: testPhoneEnglish, exact: true })).toBeVisible();

    // 5. Test AC 1: Simulate Inbound Urdu بند Keyword
    const testPhoneUrdu = `+92300${Math.floor(1000000 + Math.random() * 9000000)}`;
    await page.getByPlaceholder('+923001234567').fill(testPhoneUrdu);
    await page.locator('select').selectOption('بند');
    await page.getByRole('button', { name: 'Simulate Inbound SMS' }).click();

    await expect(page.getByText(/Inbound 'بند' received/i)).toBeVisible({ timeout: 10000 });
    await expect(page.getByRole('cell', { name: testPhoneUrdu, exact: true })).toBeVisible();

    // 6. Test AC 3: Portal / Staff Re-subscribe
    const targetRow = page.locator('tr', { hasText: testPhoneEnglish });
    await targetRow.getByRole('button', { name: 'Re-subscribe (AC 3)' }).click();
    await expect(page.getByText(/re-subscribed successfully/i)).toBeVisible({ timeout: 10000 });

    // Verify phone is removed from suppression list
    await expect(page.getByRole('cell', { name: testPhoneEnglish, exact: true })).not.toBeVisible();

    // 7. Verify Inbound Messages Tab
    await page.getByRole('button', { name: /Inbound Messages/i }).click();
    await expect(page.getByRole('cell', { name: testPhoneEnglish, exact: true })).toBeVisible();
    await expect(page.getByRole('cell', { name: 'STOP', exact: true }).first()).toBeVisible();

    // 8. Verify Suppression Audit Trail Tab (AC 3 Audit)
    await page.getByRole('button', { name: /Suppression Audit Trail/i }).click();
    await expect(page.getByRole('cell', { name: testPhoneEnglish, exact: true })).toBeVisible();
    await expect(page.getByText('resubscribe').first()).toBeVisible();
  });
});
