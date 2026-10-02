import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// Self-serve sign-up. The product is invitation-based, so the contract under
// test is deliberately narrow: sign-up creates credentials and nothing else,
// and the resulting membership-less account is sent somewhere that explains
// itself rather than into an empty app shell.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const PASSWORD = 'e2e-test-password-123!';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

test('sign-up with valid input creates an account that is not in a school yet', async ({ page }) => {
  const email = `signup-${randomUUID().slice(0, 8)}@e2e.test`;

  await page.goto('/sign-up');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Full name').fill('Ayesha Khan');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
  await page.getByLabel('Confirm password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();

  await expect(page).toHaveURL(/\/no-school$/);
  await expect(page.getByTestId('no-school')).toBeVisible();
  await expect(page.getByTestId('no-school')).toContainText('invitation');

  // The account exists in auth, carries the name it was given, and has NO
  // tenant membership — the whole point of the decision under test.
  const db = admin();
  const { data: list } = await db.auth.admin.listUsers();
  const created = list.users.find((u) => u.email === email);
  expect(created).toBeTruthy();
  expect(created!.user_metadata.full_name).toBe('Ayesha Khan');

  const { data: appUser } = await db
    .from('app_user')
    .select('user_id')
    .eq('user_id', created!.id)
    .maybeSingle();
  expect(appUser).toBeNull();

  // And it cannot reach the app: the layout bounces it straight back.
  await page.goto('/dashboard');
  await expect(page).toHaveURL(/\/no-school$/);
});

test('sign-up rejects a weak password, a mismatched confirmation and a duplicate email', async ({
  page,
}) => {
  const email = `dupe-${randomUUID().slice(0, 8)}@e2e.test`;
  await admin().auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });

  await page.goto('/sign-up');
  await page.waitForLoadState('networkidle');

  // The rules are stated on screen, not just enforced on submit.
  await expect(page.getByTestId('password-rules')).toContainText('At least 10 characters');

  // ── too short ──────────────────────────────────────────────────────────
  await page.getByLabel('Full name').fill('Test User');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password', { exact: true }).fill('short');
  await page.getByLabel('Confirm password').fill('short');
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Password must be at least 10 characters')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-up$/);

  // ── mismatched confirmation ────────────────────────────────────────────
  await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
  await page.getByLabel('Confirm password').fill('e2e-test-password-999!');
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Passwords do not match')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-up$/);

  // ── duplicate email ────────────────────────────────────────────────────
  // Answered plainly rather than neutrally: a sign-up form has to say an
  // address is taken to be usable. /forgot-password is where enumeration is
  // actually resisted.
  await page.getByLabel('Confirm password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByTestId('sign-up-error')).toContainText('already exists');
  await expect(page).toHaveURL(/\/sign-up$/);
});

test('sign-up rejects an invalid email address before it reaches the server', async ({ page }) => {
  await page.goto('/sign-up');
  await page.waitForLoadState('networkidle');

  await page.getByLabel('Full name').fill('Test User');
  await page.getByLabel('Email').fill('not-an-email');
  await page.getByLabel('Password', { exact: true }).fill(PASSWORD);
  await page.getByLabel('Confirm password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();

  await expect(page.getByText('Enter a valid email address')).toBeVisible();
  await expect(page).toHaveURL(/\/sign-up$/);
});
