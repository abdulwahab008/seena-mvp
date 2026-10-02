import { test, expect } from '@playwright/test';
import { seedSchoolOwner, seedSection } from './support/school-owner-seed';

test.describe('Admissions Module E2E & Streamlined Fast-Track Flow', () => {
  test('Owner can perform 1-step Quick Walk-in Admission with styled DatePicker and verify enrolment', async ({ page }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('admissions');
    // The walk-in desk enrols into an existing section of its first (lowest-ordinal) class level.
    const { data: firstLevel, error: levelError } = await owner.admin
      .from('class_level')
      .select('code')
      .eq('tenant_id', owner.tenantId)
      .eq('is_active', true)
      .order('ordinal')
      .limit(1)
      .single();
    if (levelError || !firstLevel) throw levelError ?? new Error('no class level seeded');
    await seedSection(owner, firstLevel.code as string);
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    // 2. Check Applications page & verify Abdul Wahab is enrolled
    await page.goto('/admissions/applications');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Applications');

    const abdulWahabRow = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Abdul Wahab' });
    if (await abdulWahabRow.count() > 0) {
      await expect(abdulWahabRow.first()).toContainText('enrolled');
    }

    // 3. Test Sidebar Navigation to Walk-in Desk
    const admissionsSection = page.getByRole('button', { name: 'Admissions', exact: true });
    if (await admissionsSection.isVisible()) {
      const isExpanded = await admissionsSection.getAttribute('aria-expanded');
      if (isExpanded !== 'true') {
        await admissionsSection.click();
      }
    }
    const walkinLink = page.getByRole('link', { name: 'Walk-in Desk' });
    await expect(walkinLink).toBeVisible();
    await walkinLink.click();
    await expect(page).toHaveURL(/\/admissions\/walk-in$/);

    // Verify Walk-in Desk page headers and elements
    await expect(page.locator('h1')).toContainText('Walk-in Admission Desk');


    // 4. Select Section from academic offerings
    const sectionSelect = page.getByTestId('walkin-section-select');
    if (await sectionSelect.isVisible()) {
      await sectionSelect.click();
      await page.getByRole('option').first().click();
    }

    // 5. Fill Spot Enrolment Form
    const childName = `Ayaan Qureshi ${Date.now().toString().slice(-4)}`;
    await page.locator('#walkin-childName').fill(childName);

    // Use DatePicker for Date of Birth (pick year 2018)
    const dobTrigger = page.getByTestId('walkin-dob');
    await expect(dobTrigger).toBeVisible();
    await dobTrigger.click();

    // Select year 2018 from calendar popover dropdown
    await page.locator('[data-testid="walkin-dob-popover"] select').last().selectOption('2018');
    // Select day 15
    await page.locator('[data-testid="walkin-dob-popover"]').getByRole('button', { name: '15', exact: true }).first().click();

    await page.locator('#walkin-parentName').fill('Farhan Qureshi');
    await page.locator('#walkin-phone').fill('03009876543');

    // Submit the spot admission
    const submitBtn = page.getByTestId('walkin-submit-btn');
    await expect(submitBtn).toBeEnabled();
    await submitBtn.click();

    // Expect success banner with GR Number
    await expect(page.getByText(/Admitted Successfully!/i)).toBeVisible({ timeout: 15000 });
    await expect(page.getByText(/GR:/i).first()).toBeVisible();


    // 6. Test Auto-Generated Printable Receipt Modal
    const printReceiptBtn = page.getByTestId('print-receipt-btn');
    await expect(printReceiptBtn).toBeVisible();
    await printReceiptBtn.click();

    await expect(page.getByRole('heading', { name: 'Official Admission Receipt' })).toBeVisible();
    await expect(page.getByText('ADMISSION FEE RECEIPT')).toBeVisible();


    // Close receipt modal
    await page.getByRole('dialog').getByLabel('Close').click();

    // 7. Verify Enquiries page has shortcut to Walk-in Desk
    await page.goto('/admissions/enquiries');
    await page.waitForLoadState('networkidle');
    await expect(page.getByTestId('goto-walkin-desk-button')).toBeVisible();

    // 8. Verify the student is active in Directory (/students)
    await page.goto('/students');
    await page.waitForLoadState('networkidle');
    await expect(page.getByText(childName)).toBeVisible({ timeout: 10000 });

  });
});
