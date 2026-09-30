import { test, expect } from '@playwright/test';

test('Subject catalog, adding new subject, and verifying competency & class curriculum dropdowns', async ({ page }) => {
  // 1. Log in as School Owner
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill('owner@seena.academy');
  await page.getByLabel('Password').fill('Password123!');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL('**/dashboard', { timeout: 15000 });

  // 2. Navigate to Master Subject Catalog
  await page.goto('/academic-setup/subjects');
  await page.waitForLoadState('networkidle');

  // Verify header and seeded subjects
  await expect(page.getByText('Master Subject Catalog')).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Mathematics', exact: true })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'Physics', exact: true })).toBeVisible();
  await expect(page.getByRole('cell', { name: 'English', exact: true })).toBeVisible();

  // Capture screenshot of Subject Catalog Desk
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/subject_catalog_desk.png',
  });

  // 3. Open "Add Subject" modal
  await page.getByRole('button', { name: 'Add Subject' }).first().click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Add New Subject')).toBeVisible();

  // Capture screenshot of Add Subject modal
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/subject_modal_add.png',
  });

  // Fill in new subject details (Strictly English)
  const rand = Math.floor(Math.random() * 899 + 100);
  const newCode = `RB${rand}`;
  const newName = `Robotics ${rand}`;

  await page.locator('#subjectCode').fill(newCode);
  await page.locator('#subjectName').fill(newName);
  // Select Elective Option
  await page.getByRole('button', { name: /Elective Option/i }).click();
  await page.locator('#defaultMarks').fill('100');

  // Submit form
  await page.getByRole('button', { name: 'Add Subject' }).last().click();

  // Verify toast
  await expect(page.getByText(`Subject "${newName}" added to catalog.`)).toBeVisible();
  await expect(page.getByRole('cell', { name: newName, exact: true })).toBeVisible();

  // 4. Verify Teacher Competency page has active subjects in dropdown
  await page.goto('/academic-setup/competency');
  await page.waitForLoadState('networkidle');

  const subjectTrigger = page.getByTestId('competency-subject-trigger');
  await expect(subjectTrigger).toBeVisible();
  await subjectTrigger.click();

  // Verify that seeded subjects and newly added subject appear
  await expect(page.getByRole('option', { name: 'Mathematics' })).toBeVisible();
  await expect(page.getByRole('option', { name: 'Physics' })).toBeVisible();
  await expect(page.getByRole('option', { name: newName })).toBeVisible();

  // Capture screenshot of Teacher Competency dropdown open
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/teacher_competency_subjects_populated.png',
  });

  // Select Mathematics
  await page.getByRole('option', { name: 'Mathematics' }).click();

  // 5. Verify Curriculum Mapping page has active subjects in dropdown for assigning to classes
  await page.goto('/academic-setup/curriculum');
  await page.waitForLoadState('networkidle');

  const curriculumSubjectTrigger = page.getByTestId('curriculum-subject-trigger');
  await expect(curriculumSubjectTrigger).toBeVisible();
  await curriculumSubjectTrigger.click();

  await expect(page.getByRole('option', { name: 'Mathematics' })).toBeVisible();
  await expect(page.getByRole('option', { name: 'Physics' })).toBeVisible();

  // Capture screenshot of Curriculum Mapping with subjects
  await page.screenshot({
    path: '/Users/apple/.gemini/antigravity-ide/brain/de9e9246-da95-45f4-b793-8e983c2bf942/curriculum_mapping_subjects_available.png',
  });
});
