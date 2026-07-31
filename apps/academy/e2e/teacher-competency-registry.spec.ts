import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithTeacherAndSubject() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@competency-e2e.test`;
  const password = 'e2e-test-password-123!';
  const teacherName = 'Ayesha Malik';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `competency-e2e-${runId}`,
    p_legal_name: `Competency E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (e1) throw e1;
  const { data: campus, error: eCampus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  if (eCampus || !campus) throw eCampus ?? new Error('campus not seeded');

  const { data: ownerUser, error: e2 } = await admin.auth.admin.createUser({ email: ownerEmail, password, email_confirm: true });
  if (e2 || !ownerUser.user) throw e2 ?? new Error('owner creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: ownerUser.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  // Seeded directly, same as leave-flow.spec.ts's own seeding: create_staff's
  // FORBIDDEN check reads JWT claims a service-role call never carries.
  const { error: e4 } = await admin.from('staff').insert({
    tenant_id: tenantId as string,
    campus_id: campus.id,
    employee_code: 'T-0001',
    cnic: '42101-1234005-1',
    gender: 'female',
    full_name: teacherName,
  });
  if (e4) throw e4;

  const { error: e5 } = await admin
    .from('subject')
    .insert({ tenant_id: tenantId as string, code: 'CHEM', name_en: 'Chemistry', name_ur: 'کیمسٹری' });
  if (e5) throw e5;

  return { ownerEmail, password, teacherName };
}

test('an owner declares a teacher competency, verifies it, and finds it via the substitute finder', async ({ page }) => {
  const { ownerEmail, password, teacherName } = await seedOwnerWithTeacherAndSubject();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(ownerEmail);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/academic-setup/competency');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('competency-staff-trigger').click();
  await page.getByRole('option', { name: teacherName, exact: true }).click();
  await page.getByTestId('competency-subject-trigger').click();
  await page.getByRole('option', { name: 'Chemistry', exact: true }).click();
  await page.getByTestId('competency-min-class-trigger').click();
  await page.getByRole('option', { name: 'Class 9', exact: true }).click();
  await page.getByTestId('competency-max-class-trigger').click();
  await page.getByRole('option', { name: 'Class 12', exact: true }).click();
  await page.getByRole('button', { name: 'Declare competency' }).click();

  await expect(page.getByText('Competency saved.')).toBeVisible();
  const row = page.getByTestId(`competency-row-${teacherName}-Chemistry`);
  await expect(row).toBeVisible();
  await expect(row).toContainText('Class 9');
  await expect(row).toContainText('Class 12');
  await expect(row).toContainText('DECLARED');

  // AC: HR verifies the competency against a document.
  await row.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByText('Competency verified.')).toBeVisible();
  await expect(row).toContainText('VERIFIED');
  await expect(row.getByRole('button', { name: 'Verify' })).not.toBeVisible();

  // AC: the substitute finder returns her for a class within her range.
  await page.getByTestId('find-substitute-subject-trigger').click();
  await page.getByRole('option', { name: 'Chemistry', exact: true }).click();
  await page.getByTestId('find-substitute-class-trigger').click();
  await page.getByRole('option', { name: 'Class 9', exact: true }).click();
  await page.getByRole('button', { name: 'Find substitutes' }).click();

  const candidate = page.getByTestId(`substitute-candidate-${teacherName}`);
  await expect(candidate).toBeVisible();
  await expect(candidate).toContainText('VERIFIED');
  await expect(candidate).not.toContainText('out of class range');
});
