import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S06: choosing WhatsApp is validated against the tenant's approved templates when the
// subscription is saved; a missing template is named, not discovered at send time.

test('WhatsApp needs an approved template for the chosen language, checked at save time', async ({ page }) => {
  test.setTimeout(120000);
  const { db, email, tenant } = await seedFeesTenant(1, 'wadigest-e2e');
  const { data: me } = await db.from('app_user').select('user_id').eq('tenant_id', tenant).limit(1).single();
  await db.from('app_user').update({ phone_e164: '+923001112233' }).eq('user_id', me!.user_id);
  const seeded = await db.rpc('seed_digest_wa_templates', { p_tenant_id: tenant });
  expect(seeded.error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/reports/digests');
  await page.waitForLoadState('networkidle');
  await expect(page.getByTestId('wa-templates')).toContainText('daily_summary_v1');
  await expect(page.getByTestId('wa-templates')).toContainText('5 variables');

  // Urdu has no approved template: rejected, naming it.
  await page.locator('#channel').selectOption('whatsapp');
  await page.locator('#languageCode').selectOption('ur');
  await page.getByTestId('subscribe').click();
  await expect(page.getByTestId('subscribe-error')).toContainText('daily_summary_v1');
  await expect(page.getByTestId('subscribe-error')).toContainText('ur');
  await expect(page.getByTestId('subscription-row')).toHaveCount(0);

  // English has one: saved.
  await page.locator('#languageCode').selectOption('en');
  await page.getByTestId('subscribe').click();
  await expect(page.getByTestId('subscription-row')).toHaveCount(1);
  await expect(page.getByTestId('subscription-row')).toContainText('WhatsApp');
});
