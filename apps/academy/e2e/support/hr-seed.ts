import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import type { Page } from '@playwright/test';
import { expect } from '@playwright/test';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
export const HR_SEED_PASSWORD = 'e2e-test-password-123!';

// A light school for the Staff & HR flows: a tenant, a campus, and a helper
// that mints users of any role (with a matching staff record when asked).
export async function seedHrTenant(label: string) {
  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@${label}.test`;
  const { data: tenant, error } = await db.rpc('provision_tenant', { p_slug: `${label}-${runId}`, p_legal_name: `${label} ${runId}`, p_owner_email: ownerEmail });
  if (error) throw new Error(`provision: ${error.message}`);
  const tenantId = tenant as string;
  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenantId).single();
  const campusId = campus!.id as string;

  let seq = 0;
  async function mkUser(suffix: string, role: string, opts: { staff?: { contractType?: string; doj?: string; mobile?: string } } = {}) {
    seq += 1;
    const email = `${suffix}-${runId}@${label}.test`;
    const { data, error: uerr } = await db.auth.admin.createUser({ email, password: HR_SEED_PASSWORD, email_confirm: true });
    if (uerr) throw new Error(`createUser: ${uerr.message}`);
    const userId = data.user!.id;
    await db.from('app_user').insert({ user_id: userId, tenant_id: tenantId, app_role: role, full_name: `${suffix} user` });
    await db.from('user_campus').insert({ user_id: userId, tenant_id: tenantId, campus_id: campusId });
    let staffId: string | null = null;
    if (opts.staff) {
      const { data: s, error: serr } = await db
        .from('staff')
        .insert({
          tenant_id: tenantId, campus_id: campusId, user_id: userId, employee_code: `E2E-${runId}-${seq}`,
          cnic: `42101-${String(1000000 + seq * 7).slice(0, 7)}-${seq % 10}`, gender: 'female',
          contract_type: opts.staff.contractType ?? 'permanent', doj: opts.staff.doj ?? '2020-01-01', full_name: `${suffix} user`,
        })
        .select('id')
        .single();
      if (serr) throw new Error(`staff: ${serr.message}`);
      staffId = s!.id as string;
      if (opts.staff.mobile) await db.from('staff_private_contact').insert({ staff_id: staffId, mobile: opts.staff.mobile });
    }
    return { email, userId, staffId, fullName: `${suffix} user` };
  }
  const owner = await mkUser('owner', 'owner');
  return { db, tenantId, campusId, runId, mkUser, owner };
}

/** A supabase-js client signed in as this user, for calling RPCs the way the app does. */
export async function userClient(email: string) {
  const c = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: HR_SEED_PASSWORD });
  if (error) throw new Error(`sign-in ${email}: ${error.message}`);
  return c;
}

export async function signInAs(page: Page, email: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(HR_SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);
}
