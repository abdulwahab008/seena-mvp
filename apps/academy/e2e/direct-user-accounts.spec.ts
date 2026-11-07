import { test, expect, type Page } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { seedFreshOwner } from './fixtures/fresh-owner';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';

async function signIn(page: Page, id: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(id);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('an owner creates a username login, and the teacher must change the temporary password', async ({ browser }) => {
  const owner = await seedFreshOwner('accounts');
  const { data: tenant } = await createClient(SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } })
    .from('tenant')
    .select('slug')
    .eq('id', owner.tenantId)
    .single();
  const username = `t${randomUUID().slice(0, 6)}`;
  const loginId = `${username}@${tenant!.slug}`;

  const ownerPage = await (await browser.newContext()).newPage();
  await signIn(ownerPage, owner.email, owner.password);
  await expect(ownerPage).toHaveURL(/\/dashboard$/);
  await ownerPage.goto('/users');
  await expect(ownerPage.getByRole('heading', { name: 'User accounts' })).toBeVisible();

  await ownerPage.getByTestId('new-account').click();
  await ownerPage.getByLabel('Full name').fill('Ahmed Tariq');
  await ownerPage.getByTestId('account-role').selectOption('subject_teacher');
  await ownerPage.getByRole('textbox', { name: 'Username' }).fill(username);
  await ownerPage.getByLabel('Temporary password').fill('Temporary-pass-1');
  await ownerPage.getByRole('button', { name: 'Create login' }).click();
  await expect(ownerPage.getByTestId(`account-${loginId}`)).toContainText('Ahmed Tariq');

  const teacherPage = await (await browser.newContext()).newPage();
  await signIn(teacherPage, loginId, 'Temporary-pass-1');
  await expect(teacherPage).toHaveURL(/\/change-password$/);
  await teacherPage.getByLabel('New password', { exact: true }).fill('My-own-password-9');
  await teacherPage.getByLabel('Confirm new password').fill('My-own-password-9');
  await teacherPage.getByRole('button', { name: 'Save password' }).click();
  await expect(teacherPage).toHaveURL(/\/dashboard$/);

  const row = ownerPage.getByTestId(`account-${loginId}`);
  await row.getByRole('button', { name: 'Turn off' }).click();
  await expect(row.getByTestId('account-status')).toHaveText('Off');

  const lockedOut = await (await browser.newContext()).newPage();
  await signIn(lockedOut, loginId, 'My-own-password-9');
  await expect(lockedOut.getByTestId('account-turned-off')).toBeVisible();
});
