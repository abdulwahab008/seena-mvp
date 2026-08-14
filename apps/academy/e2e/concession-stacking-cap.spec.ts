import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithPublishedStructure() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@stacking-cap-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `stacking-cap-e2e-${runId}`,
    p_legal_name: `Stacking Cap E2E School ${runId}`,
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
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: classLevel } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classLevel!.id,
    name: 'A',
    capacity: 5,
  });
  if (e4) throw e4;

  const { data: tuition, error: e5 } = await admin
    .from('fee_head')
    .insert({
      tenant_id: tenantId as string,
      code: 'TUITION',
      name_en: 'Tuition Fee',
      name_ur: 'فیس تعلیم',
      is_mandatory: true,
      default_frequency: 'monthly',
    })
    .select('id')
    .single();
  if (e5) throw e5;

  const { data: structure, error: e6 } = await admin
    .from('fee_structure')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      status: 'published',
      published_at: new Date().toISOString(),
    })
    .select('id')
    .single();
  if (e6) throw e6;

  const { error: e7 } = await admin.from('fee_structure_line').insert({
    structure_id: structure!.id,
    class_id: classLevel!.id,
    fee_head_id: tuition!.id,
    amount_paisa: 500000,
    frequency: 'monthly',
  });
  if (e7) throw e7;

  return { email, password };
}

test('an owner caps stacked concessions and the monthly challan job honours it', async ({ page }) => {
  const { email, password } = await seedOwnerWithPublishedStructure();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  // Set the tenant-wide stacking cap to 50%.
  await page.goto('/fees/concessions');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Max stacked concession (%)').fill('50');
  await page.getByTestId('save-fee-policy-button').click();
  await expect(page.getByText('Fee policy saved.')).toBeVisible();

  // Two overlapping 30% and 40% schemes, both on TUITION.
  await page.getByLabel('Code').fill('SIB30');
  await page.getByLabel('Name (English)').fill('Sibling 30%');
  await page.getByLabel('Name (Urdu)').fill('بہن بھائی 30%');
  await page.getByLabel('Value (% or PKR)').fill('30');
  await page.getByText('Tuition Fee', { exact: true }).click();
  await page.getByRole('button', { name: 'Add scheme' }).click();
  await expect(page.getByText('Sibling 30% created.')).toBeVisible();

  await page.getByLabel('Code').fill('MERIT40');
  await page.getByLabel('Name (English)').fill('Merit 40%');
  await page.getByLabel('Name (Urdu)').fill('میرٹ 40%');
  await page.getByLabel('Value (% or PKR)').fill('40');
  await page.getByText('Tuition Fee', { exact: true }).click();
  await page.getByRole('button', { name: 'Add scheme' }).click();
  await expect(page.getByText('Merit 40% created.')).toBeVisible();

  // Admit a student and enrol them.
  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Male', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Stacking Cap Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  // Request and approve both awards — owner bypasses the scheme's own
  // approver_role, same as every other approval flow in this module.
  await page.getByTestId('award-scheme-trigger').click();
  await page.getByRole('option', { name: 'Sibling 30%' }).click();
  await page.getByLabel('Value').fill('30');
  await page.getByLabel('From').fill('2026-08-01');
  await page.getByLabel('To').fill('2026-12-31');
  await page.getByRole('button', { name: 'Request' }).click();
  await expect(page.getByText('Concession award requested.')).toBeVisible();

  await page.getByTestId('award-scheme-trigger').click();
  await page.getByRole('option', { name: 'Merit 40%' }).click();
  await page.getByLabel('Value').fill('40');
  await page.getByLabel('From').fill('2026-08-01');
  await page.getByLabel('To').fill('2026-12-31');
  await page.getByRole('button', { name: 'Request' }).click();
  await expect(page.getByText('Concession award requested.')).toBeVisible();

  const approveButtons = page.getByRole('button', { name: 'Approve' });
  await approveButtons.first().click();
  await expect(page.getByText('Award approved.').first()).toBeVisible();
  await approveButtons.first().click();
  await expect(page.getByText('Award approved.').last()).toBeVisible();

  // Generate the challan: 30% + 40% (350000 paisa raw) caps at 50% of the
  // 500000-paisa TUITION line — exactly 250000 paisa, net 250000.
  await page.goto('/fees/challans');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('challan-period-input').fill('2026-08');
  await page.getByTestId('generate-button').click();
  await expect(page.getByText('Challans generated.')).toBeVisible();

  const challanRow = page.locator('[data-testid^="challan-row-"]');
  await expect(challanRow).toContainText('Net PKR 2,500');
});
