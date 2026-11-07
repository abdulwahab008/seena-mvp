import { test, expect } from '@playwright/test';
import { seedFreshOwner } from './fixtures/fresh-owner';
import { createClient } from '@supabase/supabase-js';

test('the front desk logs a visitor in and signs them out, and a gate pass', async ({ page }) => {
  const owner = await seedFreshOwner('frontdesk');
  const admin = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321', process.env.SUPABASE_SERVICE_ROLE_KEY!, { auth: { persistSession: false } });
  const { data: u } = await admin.from('app_user').select('user_id').eq('tenant_id', owner.tenantId).single();
  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', owner.tenantId).single();
  await admin.from('user_campus').insert({ user_id: u!.user_id, tenant_id: owner.tenantId, campus_id: campus!.id });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(owner.email);
  await page.getByLabel('Password').fill(owner.password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/front-desk');
  await expect(page.getByRole('heading', { name: 'Front desk' })).toBeVisible();
  await page.getByLabel('Visitor name').fill('Mr Khan');
  await page.getByLabel('Purpose of visit').fill('Meet the principal');
  await page.getByRole('button', { name: 'Save' }).click();
  const row = page.getByTestId('front-desk-entry').filter({ hasText: 'Mr Khan' });
  await expect(row.getByTestId('entry-open')).toHaveText('Inside');
  await row.getByRole('button', { name: 'Sign out' }).click();
  await expect(row).toContainText('Sign out');
  await expect(row.getByTestId('entry-open')).toHaveCount(0);

  await page.getByRole('link', { name: 'Gate passes' }).click();
  await page.getByLabel('Student or staff name').fill('Ali Raza');
  await page.getByLabel('Reason').fill('Doctor appointment');
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('front-desk-entry').filter({ hasText: 'Ali Raza' }).getByTestId('entry-open')).toHaveText('Out');
  await expect(page.getByRole('link', { name: 'Gate passes (1)' })).toBeVisible();
});
