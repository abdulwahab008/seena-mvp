import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test.describe('FR-M03 · FR-M04: Message Template Library & SMS Segment Engine End-to-End Flow', () => {
  test('Principal / Owner can browse templates, compose with whitelisted tokens, preview Urdu/English, and publish immutable versions', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('comm-templates');
    // The library's starter templates are only backfilled for tenants that existed when the migration ran.
    const { error: seedError } = await owner.admin.rpc('seed_default_versioned_templates', {
      p_tenant_id: owner.tenantId,
    });
    if (seedError) throw seedError;
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Message Template Library
    await page.goto('/communication/templates');
    await page.waitForLoadState('networkidle');

    // 3. Verify Page Header and Badges
    await expect(page.locator('h1')).toContainText('Message Template Library');
    await expect(page.getByText('FR-M03 · FR-M04')).toBeVisible();

    // 4. Verify seeded templates exist
    await expect(page.getByRole('heading', { name: 'Student Absence Alert' }).first()).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Monthly Fee Challan Due Notice' }).first()).toBeVisible();

    // 5. Open Create Template Modal
    await page.getByRole('button', { name: 'New Template' }).click();
    await expect(page.getByText('Create Message Template')).toBeVisible();

    const uniqueId = Date.now();
    const templateName = `Annual Sports Notification ${uniqueId}`;

    await page.getByPlaceholder('e.g. Student Absence Notice').fill(templateName);

    // Click a whitelisted placeholder token pill to insert into English body
    const studentTokenPill = page.getByRole('button', { name: '{{student_name}}' }).first();
    await expect(studentTokenPill).toBeVisible();
    await studentTokenPill.click();

    // Type the rest of the body
    const englishTextarea = page.getByTestId('create-body-en');
    const currentVal = await englishTextarea.inputValue();
    await englishTextarea.fill(
      `${currentVal} has been selected for the annual inter-school athletics meet. Please confirm participation.`
    );

    // Enter Urdu body with Nastaliq script
    const urduTextarea = page.getByTestId('create-body-ur');
    await urduTextarea.fill(
      'محترم والدین، آپ کے بچے کو سالانہ کھیلوں کے مقابلے کے لیے منتخب کیا گیا ہے۔'
    );

    // Verify SMS segment counter reflects UCS-2 encoding for Urdu
    await expect(page.getByText(/UCS-2/i).first()).toBeVisible();

    // Submit and publish
    await page.getByRole('button', { name: 'Save & Publish' }).click();

    // 6. Verify newly published template appears in list
    await expect(page.getByRole('heading', { name: templateName })).toBeVisible({ timeout: 10000 });
    const templateCard = page.locator('div.border.rounded-lg', { hasText: templateName }).first();
    await expect(templateCard.getByText('v1')).toBeVisible();

    // 7. Test Quick Preview / Variable Rendering Modal
    const testBtn = templateCard.getByRole('button', { name: 'Test' });
    await expect(testBtn).toBeVisible();
    await testBtn.click();

    await expect(page.getByText(/Test Render:/i)).toBeVisible();
    // Verify variable substitution renders the sample student name
    await expect(page.getByTestId('preview-output')).toContainText('Muhammad Ali');

    // Switch to Urdu render
    const urduTab = page.getByRole('button', { name: 'اردو (Urdu)' });
    await expect(urduTab).toBeVisible();
    await urduTab.click();
    await expect(page.getByTestId('preview-output')).toContainText('محترم والدین');

    // Close preview modal
    await page.getByRole('button', { name: 'Close Preview' }).click();

    // 8. Open Versions Drawer and Create Version 2
    const versionsBtn = templateCard.getByRole('button', { name: 'Versions' });
    await expect(versionsBtn).toBeVisible();
    await versionsBtn.click();

    await expect(page.getByText(/Version History/i)).toBeVisible();
    await expect(page.getByText(/Compose Next Version \(v2\)/i)).toBeVisible();

    // Fill in version 2 summary
    await page
      .getByPlaceholder(/Updated fee deadline phrasing/i)
      .fill('Revision 2: Added reporting time');
    const v2Textarea = page.getByTestId('v2-body-en');
    await v2Textarea.fill(
      'Dear Guardian, {{student_name}} must report at 08:00 AM sharp for sports day.'
    );

    // Save as draft version 2
    await page.getByRole('button', { name: 'Create Draft Version' }).click();

    // 9. Verify template card reflects 2 versions
    await expect(templateCard.getByText('2 versions')).toBeVisible({ timeout: 10000 });

    // Re-open versions drawer to verify full version history list
    await versionsBtn.click();
    await expect(page.getByText('Version 2')).toBeVisible();
    await expect(page.getByText('Revision 2: Added reporting time')).toBeVisible();
  });
});
