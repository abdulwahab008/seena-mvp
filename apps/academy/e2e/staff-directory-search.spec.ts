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
  const ownerEmail = `owner-${runId}@staffdir-e2e.test`;
  const teacherEmail = `teacher-${runId}@staffdir-e2e.test`;
  const hrEmail = `hr-${runId}@staffdir-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `staffdir-e2e-${runId}`,
    p_legal_name: `Staff Directory E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: teacherUser, error: e4 } = await admin.auth.admin.createUser({ email: teacherEmail, password, email_confirm: true });
  if (e4 || !teacherUser.user) throw e4 ?? new Error('teacher creation failed');
  const { error: e5 } = await admin
    .from('app_user')
    .insert({ user_id: teacherUser.user.id, tenant_id: tenantId as string, app_role: 'subject_teacher', full_name: 'Searching Teacher' });
  if (e5) throw e5;

  const { data: hrUser, error: e6 } = await admin.auth.admin.createUser({ email: hrEmail, password, email_confirm: true });
  if (e6 || !hrUser.user) throw e6 ?? new Error('hr creation failed');
  const { error: e7 } = await admin
    .from('app_user')
    .insert({ user_id: hrUser.user.id, tenant_id: tenantId as string, app_role: 'hr_manager', full_name: 'HR Manager' });
  if (e7) throw e7;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { error: e3b } = await admin
    .from('user_campus')
    .insert([
      { user_id: teacherUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id },
      { user_id: hrUser.user.id, tenant_id: tenantId as string, campus_id: campus!.id },
    ]);
  if (e3b) throw e3b;

  // FR-D19 has no dedicated "add staff" UI yet — create_staff() is seeded
  // through the owner's own authenticated session, the same convention
  // this suite already uses for other not-yet-UI-exposed RPCs.
  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password });
  if (signInError) throw signInError;

  const { data: ahmedId, error: e8 } = await ownerClient.rpc('create_staff', {
    p_campus_id: campus!.id,
    p_full_name: 'Ahmed Raza',
    p_gender: 'male',
    p_cnic: '42101-1234567-1',
  });
  if (e8) throw e8;

  const { data: bilalId, error: e9 } = await ownerClient.rpc('create_staff', {
    p_campus_id: campus!.id,
    p_full_name: 'Bilal Khan',
    p_gender: 'male',
    p_cnic: '42101-1234567-2',
  });
  if (e9) throw e9;

  // staff_private_contact has no INSERT policy at all (defense-in-depth,
  // read-only even for privileged roles) — seeded directly with the
  // service-role client, same as this suite seeds any other non-RPC table.
  const { error: e10 } = await admin.from('staff_private_contact').insert({ staff_id: ahmedId as string, mobile: '+923001234567' });
  if (e10) throw e10;
  const { error: e11 } = await admin.from('staff').update({ employment_status: 'exited' }).eq('id', bilalId as string);
  if (e11) throw e11;

  return { teacherEmail, hrEmail, password };
}

test('a teacher searching the staff directory never sees a colleague\'s mobile number, but HR does', async ({ page, browser }) => {
  const { teacherEmail, hrEmail, password } = await seedTenant();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(teacherEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/staff/directory');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('staff-directory-query').fill('Ahmed');
  await page.getByTestId('staff-directory-search-button').click();
  await expect(page.getByTestId('staff-directory-row-Ahmed Raza')).toBeVisible();
  await expect(page.getByTestId('staff-directory-mobile-Ahmed Raza')).toHaveText('—');
  await expect(page.getByTestId('staff-directory-idnum-Ahmed Raza')).toHaveText('—');

  // AC4: an exited staff member never appears by default.
  await page.getByTestId('staff-directory-query').fill('Bilal');
  await page.getByTestId('staff-directory-search-button').click();
  await expect(page.getByText('No staff found.')).toBeVisible();
  await page.getByTestId('staff-directory-include-former').check();
  await page.getByTestId('staff-directory-search-button').click();
  await expect(page.getByTestId('staff-directory-row-Bilal Khan')).toBeVisible();
  await expect(page.getByTestId('staff-directory-former-Bilal Khan')).toBeVisible();

  // HR Manager, in a separate context, runs the identical "Ahmed" search
  // and sees the mobile number and identity document number.
  const hrContext = await browser.newContext();
  const hrPage = await hrContext.newPage();
  await hrPage.goto('/login');
  await hrPage.waitForLoadState('networkidle');
  await hrPage.getByLabel('Email').fill(hrEmail);
  await hrPage.getByLabel('Password').fill(password);
  await hrPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(hrPage).toHaveURL(/\/dashboard$/);

  await hrPage.goto('/staff/directory');
  await hrPage.waitForLoadState('networkidle');
  await hrPage.getByTestId('staff-directory-query').fill('Ahmed');
  await hrPage.getByTestId('staff-directory-search-button').click();
  await expect(hrPage.getByTestId('staff-directory-mobile-Ahmed Raza')).toHaveText('+923001234567');
  await expect(hrPage.getByTestId('staff-directory-idnum-Ahmed Raza')).toHaveText('42101-1234567-1');
});
