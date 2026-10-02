import { test, expect } from '@playwright/test';
import { seedSchoolOwner, seedStandardDepartments, seedStaffMember } from './support/school-owner-seed';

test.describe('Teacher Departments End-to-End Flow', () => {
  test('Owner can manage departments, assign faculty, and filter staff directory by department', async ({ page }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('teacher-depts');
    // The standard departments are only backfilled for tenants that existed when the migration ran.
    await seedStandardDepartments(owner);
    // The directory search below needs this teacher to exist; file him under Sciences so the
    // reassignment to Mathematics is a real change.
    await seedStaffMember(owner, {
      fullName: 'Prof. Zafar Iqbal',
      employeeCode: 'SA-MAIN-0002',
      cnic: '42101-1234567-1',
      departmentCode: 'SCI',
    });
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL('**/dashboard', { timeout: 15000 });

    // 2. Navigate to Academic Departments
    await page.goto('/staff/departments');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Academic Departments');

    // 3. Verify standard seeded departments are present
    await expect(page.getByTestId('department-card-SCI')).toBeVisible();
    await expect(page.getByTestId('department-card-MATH')).toBeVisible();
    await expect(page.getByTestId('department-card-CS_IT')).toBeVisible();

    // 4. Create a new custom department (Sports & Physical Education)
    const addDeptBtn = page.getByTestId('add-department-button');
    await expect(addDeptBtn).toBeVisible();
    await addDeptBtn.click();

    const uniqueCode = `SP_${Math.floor(100 + Math.random() * 900)}`;
    await page.getByTestId('department-code-input').fill(uniqueCode);
    await page.getByTestId('department-name-en-input').fill('Sports & Physical Fitness');
    await page.getByTestId('save-department-button').click();

    // Verify newly created department card appears
    await expect(page.getByTestId(`department-card-${uniqueCode}`)).toBeVisible({ timeout: 10000 });

    // 5. Navigate to Staff Directory
    await page.goto('/staff/directory');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Staff Directory');

    // 6. Search for Prof. Zafar Iqbal
    await page.getByTestId('staff-directory-query').fill('Zafar');
    await page.getByTestId('staff-directory-search-button').click();
    await page.waitForLoadState('networkidle');

    const zafarRow = page.getByTestId('staff-directory-row-Prof. Zafar Iqbal');
    await expect(zafarRow).toBeVisible();

    // 7. Change department via quick inline modal to Mathematics
    const editDeptBtn = page.getByTestId('edit-dept-btn-SA-MAIN-0002');
    await expect(editDeptBtn).toBeVisible();
    await editDeptBtn.click();

    // Select Mathematics department
    const reassignSelect = page.getByTestId('reassign-dept-select');
    await expect(reassignSelect).toBeVisible();
    // Choose the option containing Mathematics
    const mathOption = await reassignSelect.locator('option').filter({ hasText: 'Mathematics' }).getAttribute('value');
    if (mathOption) {
      await reassignSelect.selectOption(mathOption);
    }
    await page.getByTestId('confirm-reassign-dept-btn').click();

    // Verify row now shows Mathematics
    await expect(page.getByTestId('staff-dept-Prof. Zafar Iqbal')).toContainText('Mathematics', { timeout: 10000 });

    // 8. Test Department Filter in Staff Directory
    const deptFilter = page.getByTestId('staff-department-filter');
    await expect(deptFilter).toBeVisible();
    await deptFilter.selectOption({ label: 'MATH — Mathematics' });

    // Prof. Zafar Iqbal must be visible under Mathematics
    await expect(page.getByTestId('staff-directory-row-Prof. Zafar Iqbal')).toBeVisible();

    // Filter by Sciences — Zafar Iqbal should not be visible
    await deptFilter.selectOption({ label: 'SCI — Sciences' });
    await expect(page.getByTestId('staff-directory-row-Prof. Zafar Iqbal')).not.toBeVisible();

    // Reset filter to All Departments
    await deptFilter.selectOption('all');
    await expect(page.getByTestId('staff-directory-row-Prof. Zafar Iqbal')).toBeVisible();
  });

  test('Department cards are minimal without clutter and Assign Modal immediately shows updated department name', async ({ page }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('teacher-depts');
    // The standard departments are only backfilled for tenants that existed when the migration ran.
    await seedStandardDepartments(owner);
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL('**/dashboard', { timeout: 15000 });

    // 2. Navigate to Academic Departments
    await page.goto('/staff/departments');
    await page.waitForLoadState('networkidle');

    // 3. Verify minimal layout: NO "Academic Wing" footer and NO "No faculty assigned to this department yet."
    await expect(page.getByText('Academic Wing')).not.toBeVisible();
    await expect(page.getByText('No faculty assigned to this department yet.')).not.toBeVisible();

    // 4. Create or edit a department to verify name reactivity
    const testCode = `TEST_${Math.floor(100 + Math.random() * 900)}`;
    const initialName = `Initial Tech ${testCode}`;
    const updatedName = `Robotics & AI ${testCode}`;

    // Add department
    await page.getByTestId('add-department-button').click();
    await page.getByTestId('department-code-input').fill(testCode);
    await page.getByTestId('department-name-en-input').fill(initialName);
    await page.getByTestId('save-department-button').click();

    const card = page.getByTestId(`department-card-${testCode}`);
    await expect(card).toBeVisible({ timeout: 10000 });
    await expect(card).toContainText(initialName);

    // Edit department name to updatedName
    const editBtn = card.locator('button[title="Edit Department"]');
    await editBtn.click();
    await page.getByTestId('department-name-en-input').fill(updatedName);
    await page.getByTestId('save-department-button').click();

    // Immediately verify card displays the updated name
    await expect(card).toContainText(updatedName, { timeout: 10000 });

    // Click "+ Assign Teacher"
    const assignBtn = page.getByTestId(`assign-faculty-btn-${testCode}`);
    await assignBtn.click();

    // Verify modal description immediately shows the UPDATED name, NOT the previous initial name
    const modalDesc = page.getByText(`Select an unassigned teacher to assign to ${updatedName}.`);
    await expect(modalDesc).toBeVisible({ timeout: 5000 });
    await expect(page.getByText(initialName)).not.toBeVisible();

    // Verify faculty select is populated
    const select = page.getByTestId('assign-faculty-select');
    await expect(select).toBeVisible();

    // Close modal
    await page.getByRole('button', { name: 'Cancel' }).click();
    await expect(select).not.toBeVisible();
  });
});
