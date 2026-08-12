import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const HEADER = 'gr_number,name_en,name_ur,father_name_en,father_name_ur,dob,gender,class,b_form_no,religion,nationality,blood_group';

// Row 2 is clean; row 3 has no B-Form (warning, still importable); row 4
// names a class that is not configured; rows 5 and 6 share a GR number.
const REGISTER_CSV = [
  HEADER,
  ',Ayesha Khan,,Imran Khan,,2016-04-12,female,1,42101-0000001-1,,PK,',
  ',Bilal Ahmed,,Imran Khan,,2016-05-12,male,2,,,PK,',
  ',Sana Malik,,Imran Khan,,2016-06-12,female,Class One,42101-0000002-1,,PK,',
  'PAPER-7,Hassan Ali,,Imran Khan,,2016-07-12,male,3,42101-0000003-1,,PK,',
  'PAPER-7,Zoya Ali,,Imran Khan,,2016-08-12,female,4,42101-0000004-1,,PK,',
  '',
].join('\n');

const WRONG_HEADER_CSV = ['student_name,date_of_birth,sex,class', 'Ayesha Khan,2016-04-12,female,1', ''].join('\n');

async function seedOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@import-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `import-e2e-${runId}`,
    p_legal_name: `Import E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { admin, tenantId: tenantId as string, email, password };
}

test('a principal validates a register as a dry run and sees every blocked row without importing anything', async ({ page }) => {
  const { admin, tenantId, email, password } = await seedOwner();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/students/import');
  await page.waitForLoadState('networkidle');

  // AC: a header set that does not match the published template is
  // rejected before parsing, with a link to the correct template.
  await page.getByTestId('import-file-input').setInputFiles({
    name: 'wrong-columns.csv',
    mimeType: 'text/csv',
    buffer: Buffer.from(WRONG_HEADER_CSV),
  });
  await page.getByTestId('import-submit').click();
  await expect(page.getByTestId('import-error')).toContainText('do not match the student import template');
  await expect(page.getByTestId('import-error')).toContainText('missing');
  await expect(page.getByTestId('import-report')).toHaveCount(0);

  const templateLink = page.getByTestId('import-template-link');
  await expect(templateLink).toBeVisible();
  const templateResponse = await page.request.get((await templateLink.getAttribute('href'))!);
  expect(templateResponse.ok()).toBe(true);
  expect(await templateResponse.text()).toContain('gr_number,name_en');

  // Nothing was staged: a rejected header never reaches the database.
  const { count: batchesAfterReject } = await admin
    .from('import_batch')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(batchesAfterReject).toBe(0);

  await page.getByTestId('import-file-input').setInputFiles({
    name: 'register.csv',
    mimeType: 'text/csv',
    buffer: Buffer.from(REGISTER_CSV),
  });
  await page.getByTestId('import-submit').click();

  await expect(page.getByTestId('import-report')).toBeVisible();
  await expect(page.getByTestId('import-report-ready')).toHaveText('2');
  await expect(page.getByTestId('import-report-blocked')).toHaveText('3');
  await expect(page.getByTestId('import-report-warnings')).toHaveText('1');

  // AC: every blocked row is reported with its row number, its column and
  // a message.
  await expect(page.getByTestId('import-issue-4-class')).toContainText("Unknown class 'Class One' - expected one of NUR, KG, 1..12");

  // AC: BOTH occurrences of the duplicated GR number are blocked.
  await expect(page.getByTestId('import-issue-5-gr_number')).toContainText('appears more than once in this file (rows 5, 6)');
  await expect(page.getByTestId('import-issue-6-gr_number')).toContainText('appears more than once in this file (rows 5, 6)');

  // AC: a missing B-Form is a warning; the row is still one of the two
  // counted as ready.
  await expect(page.getByTestId('import-issue-3-b_form_no')).toContainText('Warning');

  // AC: ZERO rows exist in the student table.
  const { count: studentCount } = await admin.from('student').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId);
  expect(studentCount).toBe(0);
  const { count: ledgerCount } = await admin.from('gr_ledger').select('gr_number', { count: 'exact', head: true }).eq('gr_number', 'PAPER-7');
  expect(ledgerCount).toBe(0);

  // The source file is kept, privately: an anonymous client cannot read
  // the object even knowing its exact path.
  const { data: batch } = await admin.from('import_batch').select('file_path, status, total_rows').eq('tenant_id', tenantId).single();
  expect(batch!.status).toBe('validated');
  expect(batch!.total_rows).toBe(5);
  const anon = createClient(SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!, { auth: { persistSession: false } });
  const { data: anonDownload, error: anonError } = await anon.storage.from('imports').download(batch!.file_path);
  expect(anonDownload).toBeNull();
  expect(anonError).toBeTruthy();
});
