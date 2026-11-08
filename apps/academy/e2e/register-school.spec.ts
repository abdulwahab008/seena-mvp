import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { seedHrTenant, signInAs } from './support/hr-seed';

// Public sign-up is gone. A school asks to join; the request reaches the
// platform console; school links greet people by school name.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

test('old sign-up links land on school registration, and a request shows a clear thank-you', async ({ page }) => {
  const phone = `0300${String(Math.floor(Math.random() * 1e7)).padStart(7, '0')}`;
  await page.goto('/sign-up');
  await expect(page).toHaveURL(/\/register-school$/);

  await page.getByRole('button', { name: 'Request my school account' }).click();
  await expect(page.getByText('Enter the school name')).toBeVisible();

  await page.getByLabel('School name').fill('Al-Noor Grammar School');
  await page.getByLabel('Your name').fill('Bilal Ahmed');
  await page.getByLabel('Mobile number').fill(phone);
  await page.getByLabel('City (optional)').fill('Lahore');
  await page.getByRole('button', { name: 'Request my school account' }).click();
  await expect(page.getByTestId('registration-sent')).toContainText('we have your request');
  await page.getByRole('link', { name: 'Back to sign in' }).click();
  await expect(page).toHaveURL(/\/login$/);

  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data } = await db.from('school_registration_request').select('school_name, status').eq('phone', phone).single();
  expect(data).toEqual({ school_name: 'Al-Noor Grammar School', status: 'new' });
});

test('a platform admin sees the request, and a school link greets people by name', async ({ page }) => {
  const { db, tenantId, owner } = await seedHrTenant('reg-console');
  const { data: users } = await db.auth.admin.listUsers({ perPage: 1000 });
  const ownerId = users.users.find((u) => u.email === owner.email)!.id;
  await db.from('platform_admin').insert({ user_id: ownerId });
  const school = `Console School ${randomUUID().slice(0, 6)}`;
  const phone = `0301${String(Math.floor(Math.random() * 1e7)).padStart(7, '0')}`;
  await db.rpc('submit_school_registration', { p_school_name: school, p_contact_name: 'Sana Khan', p_phone: phone });

  const { data: tenant } = await db.from('tenant').select('slug, name').eq('id', tenantId).single();
  await page.goto(`/login?school=${tenant!.slug}`);
  await expect(page.getByText(`Sign in to ${tenant!.name}`)).toBeVisible();

  await signInAs(page, owner.email);
  await page.goto('/platform');
  const row = page.getByTestId('registration-request').filter({ hasText: school });
  await expect(row).toContainText('Sana Khan');
  await row.getByLabel('Request status').selectOption('contacted');
  await expect.poll(async () => (await db.from('school_registration_request').select('status').eq('phone', phone).single()).data?.status).toBe('contacted');
  await db.from('platform_admin').delete().eq('user_id', ownerId);
});
