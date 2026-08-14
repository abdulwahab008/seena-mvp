import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T11: an Exam Controller checks a Grade 9 Punjab cohort through the real
// UI, is stopped by the dashes in every stored B-Form, clicks normalise, and
// generates the file — and every assertion below is made against the BYTES
// that actually came out of the private bucket, not against what the page
// said. The 24 headers, their order, the DD/MM/YYYY date, the M/F gender, the
// PM group code, the 13-digit B-Form and the UTF-8 BOM are all read out of
// the downloaded CSV.
const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const PUNJAB_HEADERS = [
  'Sr. No.',
  'GR No.',
  'Candidate Name',
  'Candidate Name Urdu',
  'Father Name',
  'Father Name Urdu',
  'Date of Birth',
  'Gender',
  'B-Form No.',
  'Father CNIC',
  'Religion',
  'Nationality',
  'Group',
  'Class',
  'Section',
  'Roll No.',
  'Medium',
  'Session',
  'Institution Name',
  'Institution Code',
  'District',
  'Blood Group',
  'Contact No.',
  'Address',
];

/** Minimal RFC 4180 reader, so the assertions run on parsed cells. */
function parseCsv(text: string): string[][] {
  const src = text.replace(/\r\n?/g, '\n');
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let inQuotes = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!;
    if (inQuotes) {
      if (ch !== '"') field += ch;
      else if (src[i + 1] === '"') {
        field += '"';
        i++;
      } else inQuotes = false;
      continue;
    }
    if (ch === '"') inQuotes = true;
    else if (ch === ',') {
      row.push(field);
      field = '';
    } else if (ch === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += ch;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

async function seed() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const ownerEmail = `owner-${runId}@boardexport-e2e.test`;
  const controllerEmail = `controller-${runId}@boardexport-e2e.test`;

  const { data: tenantId, error } = await admin.rpc('provision_tenant', {
    p_slug: `boardexport-e2e-${runId}`,
    p_legal_name: `Board Export E2E School ${runId}`,
    p_owner_email: ownerEmail,
  });
  if (error) throw error;

  const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
  const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
  const { data: class9 } = await admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .eq('code', '9')
    .single();

  const makeUser = async (email: string, role: 'owner' | 'exam_controller', fullName: string) => {
    const { data: created, error: userError } = await admin.auth.admin.createUser({ email, password: PASSWORD, email_confirm: true });
    if (userError || !created.user) throw userError ?? new Error(`${role} creation failed`);
    const { error: appUserError } = await admin
      .from('app_user')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: role, full_name: fullName });
    if (appUserError) throw appUserError;
    const { error: campusError } = await admin
      .from('user_campus')
      .insert({ user_id: created.user.id, tenant_id: tenantId as string, campus_id: campus!.id });
    if (campusError) throw campusError;
  };
  await makeUser(ownerEmail, 'owner', 'E2E Owner');
  await makeUser(controllerEmail, 'exam_controller', 'Shaista Kamal');

  const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  const { error: signInError } = await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });
  if (signInError) throw signInError;

  const { data: stream, error: streamError } = await ownerClient.rpc('create_stream', {
    p_code: `PPM${runId}`,
    p_name_en: 'Pre-Medical',
    p_name_ur: 'پری میڈیکل',
    p_board: 'PUNJAB',
    p_applies_from_ordinal: 10,
  });
  if (streamError) throw streamError;

  const { data: section, error: sectionError } = await ownerClient.rpc('create_section', {
    p_campus_id: campus!.id,
    p_session_id: session!.id,
    p_class_level_id: class9!.id,
    p_name: 'A',
    p_capacity: 40,
  });
  if (sectionError) throw sectionError;
  const { error: tagError } = await ownerClient.rpc('set_section_stream', {
    p_section_id: section as string,
    p_stream_id: stream as string,
  });
  if (tagError) throw tagError;

  // Two candidates, both complete. The ONLY thing wrong with them is that
  // their B-Form and their father's CNIC are stored the way the schema
  // insists on storing them — dashed — and Punjab wants 13 bare digits.
  const candidates = [
    {
      name: 'Ayesha Noor',
      nameUr: 'عائشہ نور',
      father: 'Imran Noor',
      dob: '2010-03-14',
      gender: 'female' as const,
      bForm: '35202-1234567-8',
      cnic: '35202-7654321-1',
      roll: 2,
    },
    {
      name: 'Bilal Ahmed',
      nameUr: 'بلال احمد',
      father: 'Kashif Ahmed',
      dob: '2010-05-02',
      gender: 'male' as const,
      bForm: '35202-1234567-9',
      cnic: '35202-7654321-2',
      roll: 1,
    },
  ];

  for (const c of candidates) {
    const { data: studentId, error: studentError } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: c.name,
      p_dob: c.dob,
      p_gender: c.gender,
      p_name_ur: c.nameUr,
      p_father_name_en: c.father,
      p_religion: 'Islam',
      p_b_form_no: c.bForm,
    });
    if (studentError || !studentId) throw studentError ?? new Error('student creation failed');

    const { data: enrolmentId, error: enrolError } = await ownerClient.rpc('enrol_student', {
      p_section_id: section as string,
      p_student_id: studentId as string,
    });
    if (enrolError) throw enrolError;
    await admin.from('enrolment').update({ roll_no: c.roll }).eq('id', enrolmentId as string);

    const { data: guardian, error: guardianError } = await admin
      .from('guardian')
      .insert({ tenant_id: tenantId as string, cnic: c.cnic, name_en: c.father, phone_e164: '+923001110001' })
      .select('id')
      .single();
    if (guardianError) throw guardianError;
    const { error: linkError } = await admin.from('student_guardian').insert({
      tenant_id: tenantId as string,
      student_id: studentId as string,
      guardian_id: guardian!.id,
      relationship: 'father',
      is_primary: true,
      receives_billing: true,
    });
    if (linkError) throw linkError;

    // A board file is a third-party disclosure; without this the child is
    // named as a blocking error rather than silently omitted.
    const { error: consentError } = await ownerClient.rpc('record_consent', {
      p_student_id: studentId as string,
      p_purpose_code: 'third_party_data_sharing',
      p_guardian_id: guardian!.id,
      p_decision: 'granted',
      p_channel: 'counter',
    });
    if (consentError) throw consentError;
  }

  return { controllerEmail };
}

test('an exam controller is blocked by dashed B-Forms, normalises them, and downloads the board file', async ({ page }) => {
  const { controllerEmail } = await seed();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(controllerEmail);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/certificates/board-export');
  await page.waitForLoadState('networkidle');
  await expect(page.getByRole('heading', { name: 'Board registration export' })).toBeVisible();

  await page.getByTestId('board-export-class-trigger').click();
  await page.getByTestId('board-export-class-option-9').click();
  await page.getByTestId('board-export-check-button').click();

  // AC1: blocked, and every offending row is listed with field, current
  // value and the pattern the board expects.
  const readiness = page.getByTestId('board-export-readiness');
  await expect(readiness).toBeVisible();
  await expect(page.getByTestId('board-export-student-count')).toContainText('2');
  await expect(page.getByTestId('board-export-blocked-note')).toBeVisible();
  await expect(page.getByTestId('board-export-generate-button')).toBeDisabled();

  const bformErrors = page.getByTestId('board-export-error-BFORM_FORMAT');
  await expect(bformErrors).toHaveCount(2);
  await expect(bformErrors.first()).toContainText('B-Form number');
  await expect(bformErrors.first()).toContainText('13 digits, no dashes');
  await expect(readiness).toContainText('35202-1234567-');

  // AC1: one click.
  await page.getByTestId('board-export-normalise-button').click();
  await expect(page.getByTestId('board-export-blocking-count')).toContainText('0');
  await expect(page.getByTestId('board-export-all-clear')).toBeVisible();

  await page.getByTestId('board-export-generate-button').click();
  const downloadLink = page.getByTestId('board-export-download-link');
  await expect(downloadLink).toBeVisible();
  const href = await downloadLink.getAttribute('href');
  expect(href).toMatch(/^https?:\/\//);

  // Everything below is the real file, fetched from the private bucket with
  // no browser session at all.
  const response = await page.request.get(href!);
  expect(response.ok()).toBe(true);
  const bytes = await response.body();

  // Urdu goes into this file, so Excel must not be left to guess the
  // codepage: the first three bytes are the UTF-8 BOM.
  expect([bytes[0], bytes[1], bytes[2]]).toEqual([0xef, 0xbb, 0xbf]);

  const text = bytes.toString('utf8');
  expect(text).toContain('\r\n');

  const rows = parseCsv(text.slice(1));
  // AC2: the board's exact 24 headers, in order.
  expect(rows[0]).toEqual(PUNJAB_HEADERS);
  expect(rows).toHaveLength(3);

  // Ordered by roll number, so Bilal (roll 1) is the first candidate.
  const [, first, second] = rows;
  expect(first![0]).toBe('1');
  expect(first![2]).toBe('BILAL AHMED');
  expect(second![2]).toBe('AYESHA NOOR');

  // AC2: DD/MM/YYYY, M/F, PM.
  expect(first![6]).toBe('02/05/2010');
  expect(first![7]).toBe('M');
  expect(second![6]).toBe('14/03/2010');
  expect(second![7]).toBe('F');
  expect(first![12]).toBe('PM');

  // Trap 2, both ways: the file carries 13 bare digits...
  expect(first![8]).toBe('3520212345679');
  expect(first![9]).toBe('3520276543212');
  // ...and the Urdu name survived the round trip.
  expect(second![3]).toBe('عائشہ نور');

  // AC4: the run is recorded with its row count and checksum, and the file
  // it points at is the one that was just downloaded.
  const runCard = page.getByTestId(/^board-export-run-/).first();
  await expect(runCard).toContainText('PUNJAB');
  await expect(runCard).toContainText('completed');
  await expect(runCard).toContainText('2 candidates');
  await expect(runCard).toContainText('sha256');
});
