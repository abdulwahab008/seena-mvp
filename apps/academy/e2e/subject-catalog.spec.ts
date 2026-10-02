import { test, expect } from '@playwright/test';
import { seedSchoolOwner, seedStandardSubjects } from './support/school-owner-seed';

test('Subject catalog, adding new subject, and verifying competency & class curriculum dropdowns', async ({ page }) => {
  // 1. Log in as School Owner
  const owner = await seedSchoolOwner('subject-catalog');
  // The standard subjects are only backfilled for tenants that existed when the migration ran.
  await seedStandardSubjects(owner);
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel('Password').fill(owner.password);
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


  // 3. Open "Add Subject" modal
  await page.getByRole('button', { name: 'Add Subject' }).first().click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await expect(page.getByText('Add New Subject')).toBeVisible();


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

});
