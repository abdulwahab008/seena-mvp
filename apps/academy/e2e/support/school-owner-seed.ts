import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';

export const SCHOOL_OWNER_PASSWORD = 'e2e-test-password-123!';

export type SeededSchoolOwner = {
  admin: SupabaseClient;
  tenantId: string;
  campusId: string;
  email: string;
  password: string;
};

/**
 * A fresh school with its own owner, provisioned through the same path every
 * other self-seeding spec uses (provision_tenant + an auth user + the owner's
 * app_user row), so a spec can sign in without depending on an account that
 * only exists on one developer's database.
 *
 * The communication/staff/curriculum specs used to sign in as a hand-created
 * owner@seena.academy; that user is not part of any migration or seed, so those
 * specs could only pass on the machine that had it (and never in CI or on a
 * database built from the migrations). Each run now builds its own tenant, so
 * runs also cannot see each other's rows.
 */
export async function seedSchoolOwner(slugPrefix: string): Promise<SeededSchoolOwner> {
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRoleKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is not set');

  const admin = createClient(SUPABASE_URL, serviceRoleKey, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@${slugPrefix}-e2e.test`;

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: `${slugPrefix}-e2e-${runId}`,
    p_legal_name: `${slugPrefix} E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;

  const { data: created, error: e2 } = await admin.auth.admin.createUser({
    email,
    password: SCHOOL_OWNER_PASSWORD,
    email_confirm: true,
  });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');

  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  const { data: campus, error: e4 } = await admin
    .from('campus')
    .select('id')
    .eq('tenant_id', tenantId as string)
    .single();
  if (e4 || !campus) throw e4 ?? new Error('campus not seeded');

  return { admin, tenantId: tenantId as string, campusId: campus.id as string, email, password: SCHOOL_OWNER_PASSWORD };
}

// ---------------------------------------------------------------------------
// Reference data the migrations only backfilled for tenants that already
// existed when they ran (or for one hard-coded dev tenant). A school
// provisioned afterwards starts without it, so a spec that asserts it is
// "seeded" has to establish it for its own tenant. The rows below are the
// ones those migrations insert.
// ---------------------------------------------------------------------------

/** 20260801200000_teacher_departments_end_to_end.sql — "standard school departments". */
export const STANDARD_DEPARTMENTS = [
  { code: 'SCI', name_en: 'Sciences', name_ur: 'شعبہ سائنسی علوم' },
  { code: 'MATH', name_en: 'Mathematics', name_ur: 'شعبہ ریاضی' },
  { code: 'ENG', name_en: 'English Language & Literature', name_ur: 'شعبہ انگریزی' },
  { code: 'URDU', name_en: 'Urdu & Regional Languages', name_ur: 'شعبہ اردو و ادبیات' },
  { code: 'CS_IT', name_en: 'Computer Science & IT', name_ur: 'شعبہ کمپیوٹر سائنس' },
  { code: 'ISL_PST', name_en: 'Islamic & Pakistan Studies', name_ur: 'اسلامیات و مطالعہ پاکستان' },
  { code: 'SOC_HUM', name_en: 'Social Studies & Humanities', name_ur: 'معاشرتی علوم و ہیومینٹیز' },
  { code: 'PRI', name_en: 'Primary & Junior Section', name_ur: 'ابتدائی و جونیئر شعبہ' },
] as const;

export async function seedStandardDepartments(owner: SeededSchoolOwner): Promise<void> {
  const { error } = await owner.admin
    .from('department')
    .upsert(
      STANDARD_DEPARTMENTS.map((d) => ({ tenant_id: owner.tenantId, ...d })),
      { onConflict: 'tenant_id,code' },
    );
  if (error) throw error;
}

/** 20260801240000_subject_management_and_seeding.sql — "standard school subjects". */
export const STANDARD_SUBJECTS = [
  { code: 'ENG', name_en: 'English', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'URD', name_en: 'Urdu', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'MTH', name_en: 'Mathematics', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'SCI', name_en: 'General Science', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'PHY', name_en: 'Physics', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'CHM', name_en: 'Chemistry', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'BIO', name_en: 'Biology', subject_type: 'ELECTIVE', is_examinable: true, default_max_marks: 100 },
  { code: 'CSC', name_en: 'Computer Science', subject_type: 'ELECTIVE', is_examinable: true, default_max_marks: 100 },
  { code: 'ISL', name_en: 'Islamiyat', subject_type: 'CORE', is_examinable: true, default_max_marks: 100 },
  { code: 'PST', name_en: 'Pakistan Studies', subject_type: 'CORE', is_examinable: true, default_max_marks: 50 },
  { code: 'TQR', name_en: 'Tarjuma-tul-Quran', subject_type: 'CORE', is_examinable: true, default_max_marks: 50 },
  { code: 'SST', name_en: 'Social Studies', subject_type: 'CORE', is_examinable: true, default_max_marks: 75 },
  { code: 'ART', name_en: 'Art & Drawing', subject_type: 'NON_EXAMINABLE', is_examinable: false, default_max_marks: null },
] as const;

export async function seedStandardSubjects(owner: SeededSchoolOwner): Promise<void> {
  const { error } = await owner.admin
    .from('subject')
    .upsert(
      STANDARD_SUBJECTS.map((s) => ({ tenant_id: owner.tenantId, name_ur: s.name_en, ...s })),
      { onConflict: 'tenant_id,code' },
    );
  if (error) throw error;
}

/** 20260801400000_dynamic_audience_segments.sql — the default segments the migration seeds per campus. */
export async function seedDefaultSegments(owner: SeededSchoolOwner): Promise<void> {
  const { error } = await owner.admin.rpc('seed_default_segments', {
    p_tenant_id: owner.tenantId,
    p_campus_id: owner.campusId,
  });
  if (error) throw error;
}

/**
 * One active class section (default "Class 1 · A") in the school's current session — what the
 * registers and rosters need before they render anything but an empty state.
 */
export async function seedSection(owner: SeededSchoolOwner, classCode = '1', name = 'A'): Promise<string> {
  const { data: session, error: e1 } = await owner.admin
    .from('academic_session')
    .select('id')
    .eq('tenant_id', owner.tenantId)
    .single();
  if (e1 || !session) throw e1 ?? new Error('session not seeded');
  const { data: classLevel, error: e2 } = await owner.admin
    .from('class_level')
    .select('id')
    .eq('tenant_id', owner.tenantId)
    .eq('code', classCode)
    .single();
  if (e2 || !classLevel) throw e2 ?? new Error(`class level ${classCode} not seeded`);
  const { data: section, error: e3 } = await owner.admin
    .from('class_section')
    .insert({
      tenant_id: owner.tenantId,
      campus_id: owner.campusId,
      session_id: session.id,
      class_level_id: classLevel.id,
      name,
      capacity: 40,
    })
    .select('id')
    .single();
  if (e3 || !section) throw e3 ?? new Error('section creation failed');
  return section.id as string;
}

/** A staff directory entry, optionally filed under one of the seeded departments. */
export async function seedStaffMember(
  owner: SeededSchoolOwner,
  member: { fullName: string; employeeCode: string; cnic: string; departmentCode?: string },
): Promise<void> {
  let departmentId: string | null = null;
  if (member.departmentCode) {
    const { data, error } = await owner.admin
      .from('department')
      .select('id')
      .eq('tenant_id', owner.tenantId)
      .eq('code', member.departmentCode)
      .single();
    if (error || !data) throw error ?? new Error(`department ${member.departmentCode} not seeded`);
    departmentId = data.id as string;
  }
  const { error } = await owner.admin.from('staff').insert({
    tenant_id: owner.tenantId,
    campus_id: owner.campusId,
    employee_code: member.employeeCode,
    cnic: member.cnic,
    gender: 'male',
    contract_type: 'permanent',
    doj: '2020-01-01',
    full_name: member.fullName,
    department_id: departmentId,
  });
  if (error) throw error;
}
