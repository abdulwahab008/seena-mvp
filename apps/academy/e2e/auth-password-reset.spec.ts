import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// Forgot-password → emailed link → reset, plus every way the link can fail.
//
// The mail hop itself is not asserted here: EMAIL_FROM is Resend's shared
// onboarding@resend.dev sender, which Resend only delivers to the account
// owner's own address, so a send to an @e2e.test address is rejected by the
// provider by design. What IS asserted is everything the app controls — that
// the action really minted and recorded a recovery token, and that the link
// built from it works. The token is read back from the ledger the action
// wrote, which is the same value that goes into the email body.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const OLD_PASSWORD = 'e2e-test-password-123!';
const NEW_PASSWORD = 'e2e-new-password-456!';

function admin() {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
}

async function seedUser() {
  const email = `reset-${randomUUID().slice(0, 8)}@e2e.test`;
  const { error } = await admin().auth.admin.createUser({
    email,
    password: OLD_PASSWORD,
    email_confirm: true,
  });
  if (error) throw error;
  return email;
}

/** The token the server action just minted, straight from its own ledger. */
async function latestTokenFor(email: string) {
  const { data } = await admin()
    .from('password_reset_request')
    .select('token_hash, created_at')
    .eq('email', email)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return data?.token_hash ?? null;
}

async function requestReset(page: import('@playwright/test').Page, email: string) {
  await page.goto('/forgot-password');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByRole('button', { name: 'Send reset link' }).click();
  await expect(page.getByTestId('reset-requested')).toBeVisible();
}

test('a real address and an unknown one get the identical neutral response', async ({ page }) => {
  const real = await seedUser();

  await requestReset(page, real);
  const realText = await page.getByTestId('reset-requested').innerText();

  await requestReset(page, `ghost-${randomUUID().slice(0, 8)}@e2e.test`);
  const ghostText = await page.getByTestId('reset-requested').innerText();

  // Byte-identical: the page must not hint that one address exists.
  expect(ghostText).toBe(realText);

  // ...while only the real address actually had a token minted for it.
  expect(await latestTokenFor(real)).not.toBeNull();
});

test('a valid link changes the password, and the old one stops working', async ({ page }) => {
  const email = await seedUser();
  await requestReset(page, email);

  const tokenHash = await latestTokenFor(email);
  expect(tokenHash).not.toBeNull();

  await page.goto(`/reset-password?token_hash=${tokenHash}`);
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('reset-password-form')).toBeVisible();

  await page.getByLabel('New password', { exact: true }).fill(NEW_PASSWORD);
  await page.getByLabel('Confirm new password').fill(NEW_PASSWORD);
  await page.getByRole('button', { name: 'Update password' }).click();

  await expect(page).toHaveURL(/\/login\?reset=1$/);
  await expect(page.getByTestId('reset-success')).toBeVisible();

  // The password really changed — proven by signing in with the new one.
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(NEW_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/no-school$/);

  // ...and the old one no longer does.
  const check = await admin().auth.signInWithPassword({ email, password: OLD_PASSWORD });
  expect(check.error).not.toBeNull();
});

test('a reused link reports that it was already used', async ({ page }) => {
  const email = await seedUser();
  await requestReset(page, email);
  const tokenHash = await latestTokenFor(email);

  await page.goto(`/reset-password?token_hash=${tokenHash}`);
  await page.waitForLoadState('networkidle');
  await page.getByLabel('New password', { exact: true }).fill(NEW_PASSWORD);
  await page.getByLabel('Confirm new password').fill(NEW_PASSWORD);
  await page.getByRole('button', { name: 'Update password' }).click();
  await expect(page).toHaveURL(/\/login\?reset=1$/);

  // Same link, second time.
  await page.goto(`/reset-password?token_hash=${tokenHash}`);
  await expect(page.getByTestId('reset-token-used')).toBeVisible();
  await expect(page.getByTestId('reset-token-used')).toContainText('already been used');
  await expect(page.getByRole('link', { name: 'Request a new link' })).toBeVisible();
});

test('an expired link reports expiry rather than a generic failure', async ({ page }) => {
  const email = await seedUser();
  await requestReset(page, email);
  const tokenHash = await latestTokenFor(email);

  // Age the ledger row past the one-hour window.
  const { error } = await admin()
    .from('password_reset_request')
    .update({ created_at: new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString() })
    .eq('token_hash', tokenHash!);
  expect(error).toBeNull();

  await page.goto(`/reset-password?token_hash=${tokenHash}`);
  await expect(page.getByTestId('reset-token-expired')).toBeVisible();
  await expect(page.getByTestId('reset-token-expired')).toContainText('expired');
  await expect(page.getByRole('link', { name: 'Request a new link' })).toBeVisible();
});

test('a tampered or missing link reports that it is not recognised', async ({ page }) => {
  await page.goto('/reset-password?token_hash=not-a-real-token-at-all');
  await expect(page.getByTestId('reset-token-unknown')).toBeVisible();
  await expect(page.getByTestId('reset-token-unknown')).toContainText("don't recognise");

  await page.goto('/reset-password');
  await expect(page.getByTestId('reset-token-missing')).toBeVisible();

  // Every failure offers the same way out.
  await page.getByRole('link', { name: 'Request a new link' }).click();
  await expect(page).toHaveURL(/\/forgot-password$/);
});

test('the reset form enforces its own password rules', async ({ page }) => {
  const email = await seedUser();
  await requestReset(page, email);
  const tokenHash = await latestTokenFor(email);

  await page.goto(`/reset-password?token_hash=${tokenHash}`);
  await page.waitForLoadState('networkidle');

  await page.getByLabel('New password', { exact: true }).fill('short');
  await page.getByLabel('Confirm new password').fill('short');
  await page.getByRole('button', { name: 'Update password' }).click();
  await expect(page.getByText('Password must be at least 10 characters')).toBeVisible();

  await page.getByLabel('New password', { exact: true }).fill(NEW_PASSWORD);
  await page.getByLabel('Confirm new password').fill('something-else-entirely');
  await page.getByRole('button', { name: 'Update password' }).click();
  await expect(page.getByText('Passwords do not match')).toBeVisible();

  // The token survived both rejections — nothing was consumed.
  await page.reload();
  await expect(page.getByTestId('reset-password-form')).toBeVisible();
});
