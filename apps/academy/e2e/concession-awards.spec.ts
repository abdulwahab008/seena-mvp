import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithScheme() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@concession-award-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `concession-award-e2e-${runId}`,
    p_legal_name: `Concession Award E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();

  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 5,
  });
  if (e4) throw e4;

  const { data: tuitionHead, error: e5 } = await admin
    .from('fee_head')
    .insert({ tenant_id: tenantId as string, code: 'TUITION', name_en: 'Tuition Fee', name_ur: 'فیس تعلیم', is_mandatory: true })
    .select('id')
    .single();
  if (e5 || !tuitionHead) throw e5 ?? new Error('fee head creation failed');

  // Seeded directly (not via create_concession_scheme's RPC), same reason
  // as every other e2e spec in this suite: its FORBIDDEN check reads JWT
  // claims a service-role call never carries. approver_role is 'owner' so
  // the single seeded user can both request and approve in this spec.
  const { error: e6 } = await admin.from('concession_scheme').insert({
    tenant_id: tenantId as string,
    code: 'HARDSHIP',
    name_en: 'Hardship Award',
    name_ur: 'مالی مشکلات',
    calc_type: 'percentage',
    value: 10,
    applicable_head_ids: [tuitionHead.id],
    approver_role: 'owner',
  });
  if (e6) throw e6;

  return { email, password };
}

test('an owner requests a concession award and approves it', async ({ page }) => {
  const { email, password } = await seedOwnerWithScheme();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Concession Award Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  await page.getByTestId('award-scheme-trigger').click();
  await page.getByRole('option', { name: 'Hardship Award' }).click();
  await page.getByLabel('Value').fill('10');
  await page.getByLabel('From').fill('2026-09-01');
  await page.getByLabel('To', { exact: true }).fill('2027-03-31');
  await page.getByRole('button', { name: 'Request' }).click();
  await expect(page.getByText('Concession award requested.')).toBeVisible();

  const awardRow = page.locator('[data-testid^="award-row-"]').filter({ hasText: 'Hardship Award' });
  await expect(awardRow).toBeVisible();
  await expect(awardRow).toContainText('(pending)');

  await awardRow.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByText('Award approved.')).toBeVisible();
  await expect(awardRow).toContainText('(approved)');
});
