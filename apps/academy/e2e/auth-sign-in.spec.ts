import { test, expect } from '@playwright/test';

// Sign-in failure modes not already covered by login-lockout.spec.ts (which
// owns the wrong-password and lockout paths).

test('an unknown account is refused with the same wording as a wrong password', async ({ page }) => {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Email').fill('nobody-at-all@e2e.test');
  await page.getByLabel('Password').fill('e2e-test-password-123!');
  await page.getByRole('button', { name: 'Sign in' }).click();

  // Identical to the wrong-password message asserted in login-lockout.spec.ts,
  // so sign-in never reveals which addresses have accounts.
  await expect(page.getByText('That sign-in did not match. Check your email, username or GR number and your password.')).toBeVisible();
  await expect(page).toHaveURL(/\/login$/);
});

test('empty fields are caught client-side and never reach the server', async ({ page }) => {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');

  await page.getByRole('button', { name: 'Sign in' }).click();

  // The identifier field accepts an email OR a student GR number (FR-N09), so its
  // client-side message is "Enter email or GR number", not an email-format error.
  await expect(page.getByText('Enter your email, username or GR number')).toBeVisible();
  await expect(page.getByText('Enter your password')).toBeVisible();
  await expect(page).toHaveURL(/\/login$/);

  // An email with no password is still incomplete.
  await page.getByLabel('Email').fill('someone@e2e.test');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('Enter your password')).toBeVisible();
  await expect(page).toHaveURL(/\/login$/);
});

test('the login page links onward to school registration, mobile sign-in and password recovery', async ({ page }) => {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');

  await page.getByRole('link', { name: 'Forgot password?' }).click();
  await expect(page).toHaveURL(/\/forgot-password$/);

  await page.getByRole('link', { name: 'Back to sign in' }).click();
  await expect(page).toHaveURL(/\/login$/);

  await page.getByRole('link', { name: 'Register your school' }).click();
  await expect(page).toHaveURL(/\/register-school$/);

  await page.goto('/login');
  await page.getByRole('link', { name: 'Sign in with a code to my phone' }).click();
  await expect(page).toHaveURL(/\/login\/otp$/);
});
