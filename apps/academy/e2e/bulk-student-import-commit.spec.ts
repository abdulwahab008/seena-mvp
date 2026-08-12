import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const HEADER = 'gr_number,name_en,name_ur,father_name_en,father_name_ur,dob,gender,class,b_form_no,religion,nationality,blood_group';

// Three importable rows — one of them carrying the school's own historical
// GR number 8450 — and one blocked by an unknown class.
const REGISTER_CSV = [
  HEADER,
  ',Ayesha Khan,,Imran Khan,,2016-04-12,female,1,42101-0000001-1,,PK,',
  ',Bilal Ahmed,,Imran Khan,,2016-05-12,male,1,42101-0000002-1,,PK,',
  '8450,Hassan Ali,,Imran Khan,,2016-07-12,male,1,42101-0000003-1,,PK,',
  ',Sana Malik,,Imran Khan,,2016-06-12,female,Class One,42101-0000004-1,,PK,',
  '',
].join('\n');

const SECOND_CSV = [
  HEADER,
  ',Zoya Ali,,Imran Khan,,2016-08-12,female,1,42101-0000005-1,,PK,',
  ',Umar Farooq,,Imran Khan,,2016-09-12,male,1,42101-0000006-1,,PK,',
  '',
].join('\n');

async function seedSchool() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@commit-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `commit-e2e-${runId}`,
    p_legal_name: `Commit E2E School ${runId}`,
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
  const { data: classOne } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '1')
    .single();

  // The import enrols every student it creates, so the class needs a
  // section with seats — commit_import_batch refuses rather than inventing
  // one.
  const { error: e4 } = await admin.from('class_section').insert({
    tenant_id: tenantId as string,
    campus_id: campus!.id,
    session_id: session!.id,
    class_level_id: classOne!.id,
    name: 'A',
    capacity: 50,
  });
  if (e4) throw e4;

  return { admin, tenantId: tenantId as string, campusId: campus!.id, sessionId: session!.id, email, password };
}

test('an owner commits a validated register atomically, keeps the school GR numbers, and undoes an import inside the window', async ({
  page,
}) => {
  const { admin, tenantId, campusId, sessionId, email, password } = await seedSchool();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/campuses$/);

  await page.goto('/students/import');
  await page.waitForLoadState('networkidle');

  await page.getByTestId('import-file-input').setInputFiles({
    name: 'register.csv',
    mimeType: 'text/csv',
    buffer: Buffer.from(REGISTER_CSV),
  });
  await page.getByTestId('import-submit').click();

  await expect(page.getByTestId('import-report')).toBeVisible();
  await expect(page.getByTestId('import-report-ready')).toHaveText('3');
  await expect(page.getByTestId('import-report-blocked')).toHaveText('1');
  await expect(page.getByTestId('import-commit-state')).toHaveText('validated');

  const batchId = new URL(page.url()).searchParams.get('batch')!;

  // Validation on its own still creates nothing — FR-C14's promise holds
  // right up to the moment the commit button is pressed.
  const { count: beforeCommit } = await admin
    .from('student')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(beforeCommit).toBe(0);

  await page.getByTestId('import-commit').click();
  await expect(page.getByTestId('import-committed-rows')).toHaveText('3');
  await expect(page.getByTestId('import-commit-state')).toHaveText('committed');

  // AC1: exactly one student and one enrolment per importable row.
  const { count: students } = await admin
    .from('student')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(students).toBe(3);
  const { count: enrolments } = await admin
    .from('enrolment')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId)
    .eq('session_id', sessionId);
  expect(enrolments).toBe(3);

  // AC3: the school's own 8450 goes onto the permanent register as-is, and
  // the campus counter jumps past it so the two allocated numbers land at
  // 8451 and 8452.
  const { data: ledger } = await admin.from('gr_ledger').select('gr_number').eq('campus_id', campusId).order('gr_number');
  expect(ledger!.map((r) => r.gr_number)).toEqual(['8450', 'MAIN-008451', 'MAIN-008452']);
  const { data: sequence } = await admin.from('gr_sequence').select('next_value').eq('campus_id', campusId).single();
  expect(Number(sequence!.next_value)).toBe(8453);

  // The blocked row never became a student, and comes back as a CSV the
  // school can fix and re-upload.
  const reportLink = page.getByTestId('import-failure-report-link');
  await expect(reportLink).toBeVisible();
  const report = await page.request.get((await reportLink.getAttribute('href'))!);
  expect(report.ok()).toBe(true);
  const reportText = await report.text();
  expect(reportText).toContain('row,gr_number,name_en,class,column,code,message');
  expect(reportText).toContain('Sana Malik');
  expect(reportText).toContain('UNKNOWN_CLASS');

  // A committed batch offers no second commit — AC2's rejection, from the
  // UI's side.
  await expect(page.getByTestId('import-commit')).toHaveCount(0);

  // AC5, refused: a fee entry against one of the imported students closes
  // the door even though the 24-hour window is wide open.
  const { data: importedRow } = await admin
    .from('import_row')
    .select('enrolment_id')
    .eq('batch_id', batchId)
    .not('enrolment_id', 'is', null)
    .limit(1)
    .single();
  const { error: ledgerError } = await admin.from('fee_ledger').insert({
    tenant_id: tenantId,
    campus_id: campusId,
    enrolment_id: importedRow!.enrolment_id!,
    session_id: sessionId,
    entry_type: 'charge',
    amount_paisa: 500000,
    direction: 'debit',
  });
  if (ledgerError) throw ledgerError;

  await page.getByTestId('import-undo').click();
  await expect(page.getByTestId('import-undo-error')).toContainText('fee or attendance records');

  const { count: stillThere } = await admin
    .from('student')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(stillThere).toBe(3);

  // AC5, allowed: a second import, untouched by anything, comes straight
  // back out.
  await page.getByTestId('import-file-input').setInputFiles({
    name: 'second.csv',
    mimeType: 'text/csv',
    buffer: Buffer.from(SECOND_CSV),
  });
  await page.getByTestId('import-submit').click();
  await expect(page.getByTestId('import-report-ready')).toHaveText('2');

  await page.getByTestId('import-commit').click();
  await expect(page.getByTestId('import-committed-rows')).toHaveText('2');

  const { count: afterSecond } = await admin
    .from('student')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(afterSecond).toBe(5);

  await page.getByTestId('import-undo').click();
  await expect(page.getByTestId('import-undone')).toBeVisible();

  const { count: afterUndo } = await admin
    .from('student')
    .select('id', { count: 'exact', head: true })
    .eq('tenant_id', tenantId);
  expect(afterUndo).toBe(3);
  const { data: sequenceAfterUndo } = await admin
    .from('gr_sequence')
    .select('next_value')
    .eq('campus_id', campusId)
    .single();
  expect(Number(sequenceAfterUndo!.next_value)).toBe(8453);
});
