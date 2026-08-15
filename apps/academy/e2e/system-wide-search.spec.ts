import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenant() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const password = 'e2e-test-password-123!';
  const ownerEmail = `owner-${runId}@search-e2e.test`;
  const principalEmail = `principal-${runId}@search-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `search-e2e-${runId}`,
    p_legal_name: `Search E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: principalUser, error: e4 } = await admin.auth.admin.createUser({ email: principalEmail, password, email_confirm: true });
  if (e4 || !principalUser.user) throw e4 ?? new Error('principal creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: principalUser.user.id, tenant_id: tenantId as string, app_role: 'principal', full_name: 'Main Campus Principal' });
  if (e5) throw e5;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();

  // The principal is granted the MAIN campus only — the second campus below
  // is what proves campus scoping in the browser.
  const { error: e6 } = await admin
    .from('user_campus')
    .insert({ user_id: principalUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
  if (e6) throw e6;

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;

  const { data: dhaCampusId, error: e7 } = await ownerClient.rpc('create_campus', {
    p_code: 'DHA',
    p_name: 'DHA Campus',
  });
  if (e7) throw e7;

  // The FR's literal AC1 GR number.
  const { error: e8 } = await ownerClient.rpc('set_gr_sequence', {
    p_campus_id: campus!.id,
    p_prefix: 'GR-2019',
    p_next_value: 442,
    p_pad_width: 4,
  });
  if (e8) throw e8;

  const { data: zainabId, error: e9 } = await ownerClient.rpc('create_student', {
    p_campus_id: campus!.id,
    p_name_en: 'Zainab Tariq',
    p_dob: '2015-01-01',
    p_gender: 'female',
    p_b_form_no: '42101-9876543-2',
  });
  if (e9) throw e9;

  // name_en has no 'ahmad' in it: only the Urdu spelling can match.
  const { error: e10 } = await ownerClient.rpc('create_student', {
    p_campus_id: campus!.id,
    p_name_en: 'A. Raza',
    p_dob: '2015-04-01',
    p_gender: 'male',
    p_name_ur: 'احمد رضا',
  });
  if (e10) throw e10;

  // Same name, other campus — invisible to the MAIN-scoped principal.
  const { error: e11 } = await ownerClient.rpc('create_student', {
    p_campus_id: dhaCampusId as string,
    p_name_en: 'Ahmad Dhanvi',
    p_dob: '2015-06-01',
    p_gender: 'male',
  });
  if (e11) throw e11;

  return { ownerEmail, principalEmail, password, zainabId: zainabId as string };
}

async function signIn(page: import('@playwright/test').Page, email: string, password: string) {
  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);
}

test('the global search box finds a student by GR number and by Urdu name, and opens the record from the keyboard', async ({ page }) => {
  const { ownerEmail, password, zainabId } = await seedTenant();
  await signIn(page, ownerEmail, password);

  // AC: keyboard-reachable without touching the mouse.
  await page.keyboard.press('ControlOrMeta+k');
  const input = page.getByTestId('global-search-input');
  await expect(input).toBeFocused();

  // AC1: the GR number typed without its prefix.
  await input.fill('2019-0442');
  const zainab = page.getByTestId('global-search-result-Zainab Tariq');
  await expect(zainab).toBeVisible();
  await expect(zainab).toContainText('GR number');

  // Enter opens the first (highest-ranked) result.
  await input.press('Enter');
  await expect(page).toHaveURL(new RegExp(`/students/${zainabId}$`));

  // AC2: an English query reaching a record spelled only in Urdu.
  await page.keyboard.press('ControlOrMeta+k');
  await page.getByTestId('global-search-input').fill('ahmad');
  const urduHit = page.getByTestId('global-search-result-A. Raza');
  await expect(urduHit).toBeVisible();
  await expect(urduHit).toContainText('Urdu name');

  // Escape closes without navigating.
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('global-search-input')).toBeHidden();
});

test('a campus-scoped principal gets zero results for a name that exists only on another campus', async ({ page }) => {
  const { principalEmail, password } = await seedTenant();
  await signIn(page, principalEmail, password);

  await page.getByTestId('global-search-trigger').click();
  await page.getByTestId('global-search-input').fill('Dhanvi');

  // AC4: an empty result, not a masked row — nothing about the DHA student
  // reaches the page at all.
  await expect(page.getByTestId('global-search-empty')).toBeVisible();
  await expect(page.getByText('Ahmad Dhanvi')).toHaveCount(0);
});
