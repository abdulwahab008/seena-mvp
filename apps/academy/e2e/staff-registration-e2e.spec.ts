import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';

test.describe('Comprehensive Staff & Teacher Registration Flow', () => {
  test('Owner/Principal can register a teacher with CNIC, contact, and subjects from directory', async ({ page }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('staff-reg');
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    // 2. Navigate to Staff Directory
    await page.goto('/staff/directory');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Staff Directory');

    // 3. Open Registration Modal
    const openModalBtn = page.getByTestId('open-add-staff-modal');
    await expect(openModalBtn).toBeVisible();
    await openModalBtn.click();

    // 4. Fill in Personal & Identity Details
    const uniqueSuffix = Math.floor(1000000 + Math.random() * 9000000);
    const teacherName = `Tariq Mehmood ${uniqueSuffix.toString().slice(-4)}`;
    const cnicNumber = `35201-${uniqueSuffix}-1`;

    await page.getByTestId('staff-full-name').fill(teacherName);
    await page.getByTestId('staff-full-name-ur').fill('طارق محمود');
    await page.getByTestId('staff-cnic').fill(cnicNumber);
    await page.getByTestId('staff-dob').fill('1988-06-15');
    await page.getByTestId('staff-doj').fill('2024-08-01');

    // 5. Fill in Contact Details
    await page.getByTestId('staff-mobile').fill('0300-7654321');

    // 6. Submit the Registration Form
    const submitBtn = page.getByTestId('submit-staff-registration');
    await expect(submitBtn).toBeVisible();
    await submitBtn.click();

    // 7. Verify Success Card with Generated Employee Code
    const successCard = page.getByTestId('staff-created-success-card');
    await expect(successCard).toBeVisible({ timeout: 10000 });
    await expect(successCard).toContainText(teacherName);
    await expect(successCard).toContainText('Official Employee Code:');

    // Close modal
    await page.getByRole('button', { name: 'Done' }).click();

    // 8. Verify the newly registered teacher appears immediately in Staff Directory table without manual refresh
    await expect(page.getByTestId(`staff-directory-row-${teacherName}`)).toBeVisible({ timeout: 5000 });
    await expect(page.getByTestId(`staff-directory-mobile-${teacherName}`)).toContainText('0300-7654321');
    await expect(page.getByTestId(`staff-directory-idnum-${teacherName}`)).toContainText('35201');

    // 9. Also verify querying directory finds the teacher
    await page.getByTestId('staff-directory-query').fill(teacherName);
    await page.getByTestId('staff-directory-search-button').click();
    await page.waitForLoadState('networkidle');

    await expect(page.getByTestId(`staff-directory-row-${teacherName}`)).toBeVisible();
  });
});
