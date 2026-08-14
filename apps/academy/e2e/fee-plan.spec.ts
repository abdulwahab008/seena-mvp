import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithPublishedStructure() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@fee-plan-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `fee-plan-e2e-${runId}`,
    p_legal_name: `Fee Plan E2E School ${runId}`,
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

  // Section, fee head and the published structure are all seeded directly
  // (not via their own gated RPCs), the same way every other e2e spec in
  // this suite seeds prerequisite state — this spec's job is to prove the
  // fee PLAN auto-builds and the override flow works, not to re-prove
  // structure publishing (already covered in fee-structure.spec.ts).
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
  if (e5 || !tuitionHead) throw e5 ?? new Error('fee head creation failed');

  const { data: structure, error: e6 } = await admin
    .from('fee_structure')
    .insert({ tenant_id: tenantId as string, campus_id: campus!.id, session_id: session!.id, status: 'published', published_at: new Date().toISOString() })
    .select('id')
    .single();
  if (e6 || !structure) throw e6 ?? new Error('structure creation failed');

  const { error: e7 } = await admin.from('fee_structure_line').insert({
    structure_id: structure.id,
    class_id: classLevel!.id,
    fee_head_id: tuitionHead.id,
    amount_paisa: 500000,
    frequency: 'monthly',
    billing_month_mask: 4095,
  });
  if (e7) throw e7;

  return { email, password };
}

test('enrolling a student auto-builds a fee plan, and an override needs approval before it takes effect', async ({ page }) => {
  const { email, password } = await seedOwnerWithPublishedStructure();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/students');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('student-gender-trigger').click();
  await page.getByRole('option', { name: 'Female', exact: true }).click();
  await page.getByLabel('Name', { exact: true }).fill('Fee Plan Child');
  await page.getByLabel('Date of birth').fill('2015-04-12');
  await page.getByRole('button', { name: 'Admit student' }).click();
  await expect(page).toHaveURL(/\/students\/[0-9a-f-]+$/);

  // FR-K04: enrolling auto-snapshots the published structure's applicable line.
  await page.getByTestId('enrol-section-trigger').click();
  await page.getByRole('option', { name: 'Class 1 · A' }).click();
  await page.getByRole('button', { name: 'Enrol into section' }).click();
  await expect(page.getByText('Enrolled.')).toBeVisible();

  const feeLine = page.getByTestId('fee-plan-line-TUITION');
  await expect(feeLine).toBeVisible();
  await expect(feeLine).toContainText('PKR 5,000');

  // Propose lowering it — not live until approved.
  await feeLine.getByRole('button', { name: 'Adjust' }).click();
  await feeLine.getByPlaceholder('New amount').fill('4000');
  await feeLine.getByPlaceholder('Reason').fill('board approved staff rate');
  await feeLine.getByRole('button', { name: 'Propose' }).click();
  await expect(page.getByText('Adjustment proposed — awaiting Principal approval.')).toBeVisible();
  await expect(feeLine).toContainText('PKR 5,000');
  await expect(page.getByTestId('fee-plan-line-status-TUITION')).toContainText('Pending: PKR 4,000');

  // Approve (as owner, who also satisfies the Principal-or-above gate).
  await feeLine.getByRole('button', { name: 'Approve' }).click();
  await expect(page.getByText('Adjustment approved.')).toBeVisible();
  await expect(feeLine).toContainText('PKR 4,000');
});
