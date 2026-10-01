import { expect, type Page } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './fees-seed';

// A school (one campus, class 1 section A, TUITION fee head, published fee structure)
// with the library roles needed by the FR-O* specs.
export async function seedLibraryTenant(label: string) {
  const seed = await seedFeesTenant(0, label);
  const { db, tenant, campusId } = seed;

  const mk = async (suffix: string, role: string, fullName = `${suffix} user`) => {
    const email = `${suffix}-${tenant.slice(0, 8)}@${label}.test`;
    const { data } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
    await db.from('app_user').insert({ user_id: data.user!.id, tenant_id: tenant, app_role: role, full_name: fullName });
    await db.from('user_campus').insert({ user_id: data.user!.id, tenant_id: tenant, campus_id: campusId });
    return { email, id: data.user!.id };
  };

  return { ...seed, mk };
}

export async function signInAs(page: Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);
}
