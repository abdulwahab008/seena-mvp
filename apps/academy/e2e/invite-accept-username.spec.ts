import { test, expect } from '@playwright/test';
import { seedHrTenant } from './support/hr-seed';

test('an invitee whose earlier try left an unconfirmed account accepts, picks a username and signs in with it', async ({ page, browser, baseURL }) => {
  const { db, tenantId, runId } = await seedHrTenant('invite-user');
  const email = `owner2-${runId}@invite-user.test`;
  const { data: invite } = await db.from('tenant_invitation').insert({ tenant_id: tenantId, email, app_role: 'principal' }).select('token').single();
  // What a failed sign-up on a confirmation-required project leaves behind.
  await db.auth.admin.createUser({ email, password: 'an-old-password-1', email_confirm: false });
  const { data: tenant } = await db.from('tenant').select('slug').eq('id', tenantId).single();

  await page.goto(`/accept-invite/${invite!.token}`);
  await expect(page.getByText(`Sign in later with yourusername@${tenant!.slug}`)).toBeVisible();
  await page.getByLabel('Your full name').fill('Sana Iqbal');
  await page.getByLabel('Username (optional)').fill('sana.k');
  await page.getByLabel('Choose a password').fill('a-brand-new-password-9');
  await page.getByRole('button', { name: 'Accept invitation' }).click();
  await expect(page).toHaveURL(/\/dashboard/);

  const fresh = await browser.newContext({ baseURL: baseURL ?? undefined });
  const p2 = await fresh.newPage();
  await p2.goto('/login');
  await p2.waitForLoadState('networkidle');
  await p2.getByLabel('Email, username or GR number').fill(`sana.k@${tenant!.slug}`);
  await p2.getByLabel('Password').fill('a-brand-new-password-9');
  await p2.getByRole('button', { name: 'Sign in' }).click();
  await expect(p2).toHaveURL(/\/dashboard/);
  await fresh.close();

  const { data: member } = await db.from('app_user').select('full_name, username').eq('tenant_id', tenantId).eq('username', 'sana.k').single();
  expect(member).toEqual({ full_name: 'Sana Iqbal', username: 'sana.k' });
});
