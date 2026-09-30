import { test, expect } from '@playwright/test';

test.describe('Classes & Sections Management and Teacher Exam Presets E2E', () => {
  test('Academic Coordinator / Owner can manage sections and configure exam presets', async ({ page }) => {
    // 1. Sign in
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill('owner@seena.academy');
    await page.getByLabel('Password').fill('Password123!');
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard$/);

    // 2. Navigate to Academics -> Classes & Sections
    await page.goto('/academic-setup/classes-sections');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Classes & Sections');

    // 3. Verify metrics overview cards
    await expect(page.getByText('Class Levels', { exact: true })).toBeVisible();
    await expect(page.getByText('Active Sections', { exact: true })).toBeVisible();
    await expect(page.getByText('Enrolled Students', { exact: true })).toBeVisible();

    // 4. Test Search filter
    const searchInput = page.getByPlaceholder(/Search classes/i);
    await expect(searchInput).toBeVisible();
    await searchInput.fill('Class 1');
    await expect(page.getByText('Class 1').first()).toBeVisible();
    await searchInput.clear();

    // 5. Navigate to Exams -> Subjects & Components
    await page.goto('/exams/subjects');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Exam subjects');

    // 6. Verify Assessment Presets are visible
    await expect(page.getByTestId('preset-theory-100')).toBeVisible();
    await expect(page.getByTestId('preset-theory-75---practical-25')).toBeVisible();
    await expect(page.getByTestId('preset-theory-80---viva-20')).toBeVisible();
    await expect(page.getByTestId('preset-single-paper-50')).toBeVisible();

    // 7. Click Theory 75 + Practical 25 preset and verify components
    await page.getByTestId('preset-theory-75---practical-25').click();
    await expect(page.getByTestId('draft-total-max')).toHaveText('100');
    await expect(page.getByTestId('component-row-0')).toContainText('theory');
    await expect(page.getByTestId('component-row-1')).toContainText('practical');

    // 8. Click Theory 80 + Viva 20 preset and verify components
    await page.getByTestId('preset-theory-80---viva-20').click();
    await expect(page.getByTestId('draft-total-max')).toHaveText('100');
    await expect(page.getByTestId('component-row-0')).toContainText('theory');
    await expect(page.getByTestId('component-row-1')).toContainText('viva');

    // 9. Click Single Paper 50 preset and verify total max
    await page.getByTestId('preset-single-paper-50').click();
    await expect(page.getByTestId('draft-total-max')).toHaveText('50');
  });
});
