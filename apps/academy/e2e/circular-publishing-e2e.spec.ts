import { test, expect } from '@playwright/test';
import { seedFreshOwner } from './fixtures/fresh-owner';

test.describe('FR-M12: Circular Publishing with Attachments', () => {
  test('Principal publishes bilingual circular, validates 10MB attachment guard (AC 1), views published feed, and unpublishes (AC 4)', async ({
    page,
  }) => {
    // 1. Sign in as Owner / Principal
    const owner = await seedFreshOwner('circular-e2e');
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Circular Publishing Desk
    await page.goto('/communication/circulars');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Title and Compose Button
    await expect(page.locator('h1')).toContainText('Circular Publishing Desk');
    const composeBtn = page.locator('#compose-circular-btn');
    await expect(composeBtn).toBeVisible();

    // 4. Open Compose Modal
    await composeBtn.click();
    await expect(page.getByText('Compose New Circular')).toBeVisible();

    // 5. Test AC 1: Attachment size validation (> 10MB rejected with size message)
    const fileInput = page.locator('#circular-attachment-input');
    // Create an oversized fake buffer (11MB = 11 * 1024 * 1024 bytes)
    const oversizedBuffer = Buffer.alloc(11 * 1024 * 1024, 'a');
    await fileInput.setInputFiles({
      name: 'large_syllabus.pdf',
      mimeType: 'application/pdf',
      buffer: oversizedBuffer,
    });

    // Check that error message appears and submission is guarded
    const sizeError = page.locator('#attachment-size-error');
    await expect(sizeError).toBeVisible();
    await expect(sizeError).toContainText('exceeds the 10 MB maximum limit');

    // 6. Test Valid Circular Creation with Bilingual Content
    const circularTitle = `Midterm Examination Schedule ${Date.now()}`;
    await page.locator('#circular-title').fill(circularTitle);
    await page.locator('#body-en').fill('Dear Parents, please find the midterm datesheet attached.');
    await page.locator('#body-ur').fill('محترم والدین، شش ماہی امتحانات کا شیڈول ملاحظہ فرمائیں۔');

    // Attach a valid file (500KB)
    const validBuffer = Buffer.alloc(500 * 1024, 'b');
    await fileInput.setInputFiles({
      name: 'midterm_datesheet.pdf',
      mimeType: 'application/pdf',
      buffer: validBuffer,
    });

    // Verify attachment added to preview list
    await expect(page.getByText(/midterm_datesheet\.pdf/i)).toBeVisible();

    // 7. Submit and Publish Circular
    const submitBtn = page.locator('#submit-circular-btn');
    await submitBtn.click();

    // Verify success banner and presence in table
    await expect(page.getByText(/successfully published/i)).toBeVisible({ timeout: 10000 });
    const circularRow = page.locator('tr', { hasText: circularTitle });
    await expect(circularRow).toBeVisible();
    await expect(circularRow.getByText('published')).toBeVisible();
    await expect(circularRow.getByText(/1 files/i)).toBeVisible();

    // 8. Test AC 4: Unpublish Circular
    const unpublishBtn = circularRow.getByRole('button', { name: 'Unpublish' });
    await unpublishBtn.click();

    // Verify status changes to unpublished in desk
    await expect(circularRow.getByText('unpublished')).toBeVisible({ timeout: 10000 });

    // 9. Verify Parent Portal Circulars route exists and renders cleanly
    await page.goto('/portal/circulars');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h2')).toContainText('Official School Circulars');
  });
});
