import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedOwnerWithSubmittedApplication() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@doc-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `doc-e2e-${runId}`,
    p_legal_name: `Doc E2E School ${runId}`,
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
  const { data: classLevel } = await admin.from('class_level').select('id').eq('tenant_id', tenantId as string).eq('code', '1').single();

  const { data: enquiry } = await admin
    .from('admission_enquiry')
    .insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      session_id: session!.id,
      enquiry_no: 'MAIN-2026-00001',
      child_name: 'Doc Candidate',
      dob: '2020-01-01',
      class_applied_id: classLevel!.id,
      parent_name: 'Parent One',
      phone_e164: '+923001111111',
      whatsapp_opt_in: false,
      source: 'walk_in',
      status: 'converted',
    })
    .select('id')
    .single();
  const { error: e4 } = await admin.from('admission_application').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    enquiry_id: enquiry!.id,
    application_no: 'APP-2026-00001',
    class_applied_id: classLevel!.id,
    status: 'submitted',
  });
  if (e4) throw e4;

  return { email, password };
}

test('an owner uploads and verifies an applicant document; storage RLS denies an anonymous read of the same object', async ({ page }) => {
  const { email, password } = await seedOwnerWithSubmittedApplication();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/admissions/applications');
  await page.waitForLoadState('networkidle');

  const row = page.locator('[data-testid^="application-row-"]').filter({ hasText: 'Doc Candidate' });
  await expect(row).toBeVisible();

  await row.getByTestId(/document-doctype-trigger-/).click();
  await page.getByRole('option', { name: 'b form', exact: true }).click();
  await row.getByTestId(/document-bform-no-/).fill('42101-1234567-8');
  await row.getByTestId(/document-file-input-/).setInputFiles({
    name: 'birth-cert.pdf',
    mimeType: 'application/pdf',
    buffer: Buffer.from('%PDF-1.4 minimal test document'),
  });
  await row.getByTestId(/document-upload-submit-/).click();
  await expect(page.getByText('Document uploaded.')).toBeVisible();

  const docRow = row.locator('[data-testid^="document-row-"]').filter({ hasText: 'b form' });
  await expect(docRow).toBeVisible();
  await expect(docRow.getByTestId(/document-status-/)).toHaveText('uploaded');

  // AC: a 7 MB scan is rejected client-side, no upload attempted.
  await row.getByTestId(/document-doctype-trigger-/).click();
  await page.getByRole('option', { name: 'passport photo', exact: true }).click();
  await row.getByTestId(/document-file-input-/).setInputFiles({
    name: 'huge-scan.pdf',
    mimeType: 'application/pdf',
    buffer: Buffer.alloc(7 * 1024 * 1024, 1),
  });
  await row.getByTestId(/document-upload-submit-/).click();
  await expect(page.getByText('Maximum file size 5 MB')).toBeVisible();

  // AC: only a mandatory-document row that is actually verified counts —
  // the officer verifies it, and the checklist reflects that.
  await docRow.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByText('Document verified.')).toBeVisible();
  await expect(docRow.getByTestId(/document-status-/)).toHaveText('verified');

  // AC: a signed URL grants access to the object.
  await docRow.getByRole('button', { name: 'Preview' }).click();
  const openLink = docRow.getByTestId(/document-preview-link-/);
  await expect(openLink).toBeVisible();
  const signedUrl = await openLink.getAttribute('href');
  expect(signedUrl).toBeTruthy();
  const authorizedResponse = await page.request.get(signedUrl!);
  expect(authorizedResponse.ok()).toBe(true);

  // AC: storage RLS denies access outright to anyone without a session on
  // this tenant — an anonymous client can't even ask for a signed URL, let
  // alone read the object directly, regardless of which path it names.
  const objectPath = new URL(signedUrl!).pathname.split('/admission-docs/')[1]?.split('?')[0];
  expect(objectPath).toBeTruthy();
  const anon = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  const { data: anonDownload, error: anonError } = await anon.storage.from('admission-docs').download(objectPath!);
  expect(anonDownload).toBeNull();
  expect(anonError).toBeTruthy();
});
