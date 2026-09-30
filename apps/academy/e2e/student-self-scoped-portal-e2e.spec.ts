import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-N09: Student self-scoped portal
// Acceptance Criteria:
// 1. Dues/fee endpoints evaluated via RLS deny access (403 / 0 rows), guardian contact details hidden.
// 2. Student can only see their own marks. When show_rank is disabled, rank list and position are hidden.
// 3. Transfer Certificate issuance deprovisions student portal account within 24 hours while guardian retains archived read access.
// 4. First login with GR number and school-issued initial password forces password change before any screen renders.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const DEFAULT_STAFF_PW = 'e2e-test-password-123!';

test.describe('FR-N09: Student self-scoped portal', () => {
  test('Complete student lifecycle: GR login, mandatory password change, self-scoped data, fee denial, rank gating, and TC deprovisioning', async ({
    page,
  }) => {
    test.setTimeout(90000);
    const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const runId = randomUUID().slice(0, 8);
    const ownerEmail = `principal-${runId}@studentportal-e2e.test`;
    const parentEmail = `parent-${runId}@studentportal-e2e.test`;

    // 1. Provision tenant
    const { data: tenantId, error: provError } = await db.rpc('provision_tenant', {
      p_slug: `student-e2e-${runId}`,
      p_legal_name: `Student Portal Academy ${runId}`,
      p_owner_email: ownerEmail,
    });
    expect(provError).toBeNull();
    const tenant = tenantId as string;

    const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
    const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();

    // 2. Create Principal / Staff user for setup
    const { data: staffUser } = await db.auth.admin.createUser({
      email: ownerEmail,
      password: DEFAULT_STAFF_PW,
      email_confirm: true,
    });
    await db.from('app_user').insert({
      user_id: staffUser.user!.id,
      tenant_id: tenant,
      app_role: 'principal',
      full_name: 'Principal Tariq',
    });
    await db.from('user_campus').insert({
      user_id: staffUser.user!.id,
      tenant_id: tenant,
      campus_id: campus!.id,
    });

    const staffClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await staffClient.auth.signInWithPassword({ email: ownerEmail, password: DEFAULT_STAFF_PW });

    // 3. Configure Campus Portal Policy: min class 6, show_rank false
    await db.from('campus_portal_policy').upsert({
      campus_id: campus!.id,
      tenant_id: tenant,
      min_class_for_student_login: 6,
      show_rank: false,
    });

    // 4. Create Class 6, Section 6-A
    let { data: classLevel } = await db
      .from('class_level')
      .select('id')
      .eq('tenant_id', tenant)
      .eq('code', '6')
      .maybeSingle();

    if (!classLevel) {
      const { data: inserted } = await db
        .from('class_level')
        .insert({
          tenant_id: tenant,
          code: '6',
          name_en: 'Class 6',
          ordinal: 7,
        })
        .select('id')
        .single();
      classLevel = inserted;
    }

    const { data: section } = await db
      .from('class_section')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name: 'A',
        capacity: 30,
      })
      .select('id')
      .single();

    // Create Student Six (target student)
    const { data: sId } = await staffClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Bilal Khan',
      p_dob: '2014-05-10',
      p_gender: 'male',
    });
    const studentId = sId as string;

    const { data: enr6 } = await staffClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId,
    });
    const enrolmentId = enr6 as string;

    // Create Peer Student in same section
    const { data: peerId } = await staffClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Zainab Peer',
      p_dob: '2014-06-15',
      p_gender: 'female',
    });
    const peerStudentId = peerId as string;

    const { data: peerEnr } = await staffClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: peerStudentId,
    });
    const peerEnrolmentId = peerEnr as string;

    // Fetch GR number of Student Six
    const { data: studentRow } = await db
      .from('student')
      .select('gr_number, gr_digits')
      .eq('id', studentId)
      .single();
    expect(studentRow).toBeTruthy();
    const grNumber = studentRow!.gr_number;
    const initialPassword = `Seena@${studentRow!.gr_digits || '123456'}`;

    // Create Guardian for Student Six (for AC 1 & AC 3 checks)
    const { data: parentUser } = await db.auth.admin.createUser({
      email: parentEmail,
      password: DEFAULT_STAFF_PW,
      email_confirm: true,
    });

    const { data: guardian } = await db
      .from('guardian')
      .insert({
        tenant_id: tenant,
        name_en: 'Imran Khan (Father)',
        phone_e164: '+923009988776',
        auth_user_id: parentUser.user!.id,
      })
      .select('id')
      .single();

    await db.from('student_guardian').insert({
      tenant_id: tenant,
      student_id: studentId,
      guardian_id: guardian!.id,
      relationship: 'father',
      is_primary: true,
      receives_academic: true,
      receives_billing: true,
    });

    // Create Fee Challan for Student Six (AC 1 test)
    await db.from('fee_challan').insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      enrolment_id: enrolmentId,
      session_id: session!.id,
      student_id: studentId,
      challan_no: `CH-${runId}`,
      billing_period: '2026-09-01',
      due_date: '2026-09-15',
      gross_paisa: 750000,
      net_paisa: 750000,
      status: 'unpaid',
    });

    // Exam & Marks Setup (AC 2 test)
    const { data: examTerm } = await db
      .from('exam_term')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        code: `TERM-${runId}`,
        name: 'Midterm Examination',
        sequence: 1,
      })
      .select('id')
      .single();

    const { data: subject } = await db
      .from('subject')
      .insert({
        tenant_id: tenant,
        code: `ENG-${runId}`,
        name_en: 'English Language',
      })
      .select('id')
      .single();

    const { data: classSubject } = await db
      .from('class_subject')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        subject_id: subject!.id,
        weekly_periods: 5,
      })
      .select('id')
      .single();

    const { data: examSubject } = await db
      .from('exam_subject')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        exam_term_id: examTerm!.id,
        class_subject_id: classSubject!.id,
      })
      .select('id')
      .single();

    // Subject marks: Bilal = 95, Zainab Peer = 82
    await db.from('subject_result').insert([
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        exam_term_id: examTerm!.id,
        section_id: section!.id,
        exam_subject_id: examSubject!.id,
        enrolment_id: enrolmentId,
        subject_id: subject!.id,
        obtained: 95,
        max_marks: 100,
        is_pass: true,
      },
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        exam_term_id: examTerm!.id,
        section_id: section!.id,
        exam_subject_id: examSubject!.id,
        enrolment_id: peerEnrolmentId,
        subject_id: subject!.id,
        obtained: 82,
        max_marks: 100,
        is_pass: true,
      },
    ]);

    // Result positions: Bilal = Rank 1, Zainab Peer = Rank 2
    await db.from('result_position').insert([
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        exam_term_id: examTerm!.id,
        class_level_id: classLevel!.id,
        section_id: section!.id,
        enrolment_id: enrolmentId,
        total_obtained: 95,
        total_max: 100,
        rank_in_section: 1,
        rank_in_class: 1,
        ranked_out_of: 2,
        ranked_out_of_class: 2,
        is_ranked: true,
        rank_policy: 'include_all',
      },
      {
        tenant_id: tenant,
        campus_id: campus!.id,
        exam_term_id: examTerm!.id,
        class_level_id: classLevel!.id,
        section_id: section!.id,
        enrolment_id: peerEnrolmentId,
        total_obtained: 82,
        total_max: 100,
        rank_in_section: 2,
        rank_in_class: 2,
        ranked_out_of: 2,
        ranked_out_of_class: 2,
        is_ranked: true,
        rank_policy: 'include_all',
      },
    ]);

    // 5. Provision Student Accounts via RPC
    const { data: provisioned, error: provRpcErr } = await db.rpc('provision_student_accounts', {
      p_campus_id: campus!.id,
    });
    expect(provRpcErr).toBeNull();
    expect(provisioned).toBeTruthy();

    const bilalAccount = (provisioned as any[]).find((p) => p.student_id === studentId);
    expect(bilalAccount).toBeTruthy();

    // Verify must_change_password flag is true
    const { data: spaRow } = await db
      .from('student_portal_account')
      .select('must_change_password, status')
      .eq('student_id', studentId)
      .single();
    expect(spaRow!.must_change_password).toBe(true);
    expect(spaRow!.status).toBe('active');

    // ─────────────────────────────────────────────────────────────────────────
    // 6. AC 4: First login with GR number forces password change
    // ─────────────────────────────────────────────────────────────────────────
    await page.goto('/login');
    await page.fill('input[id="email"]', grNumber);
    await page.fill('input[id="password"]', initialPassword);
    await page.click('button[type="submit"]');

    // Forced password change screen must gate the portal
    await expect(page.locator('text=Password Change Required')).toBeVisible({ timeout: 15000 });
    await expect(page.locator('input[id="newPassword"]')).toBeVisible();

    // Confirm navigation links are NOT rendered while gated
    await expect(page.locator('text=Timetable')).not.toBeVisible();
    await expect(page.locator('text=Results')).not.toBeVisible();

    // Set new personal password
    const newStudentPassword = 'PersonalStudentPass123!';
    await page.fill('input[id="newPassword"]', newStudentPassword);
    await page.fill('input[id="confirmPassword"]', newStudentPassword);
    await page.click('button[type="submit"]');

    // After password change, student portal loads
    await expect(page.locator('text=Student Portal')).toBeVisible({ timeout: 15000 });
    await expect(page.locator(`text=${grNumber}`)).toBeVisible();

    // ─────────────────────────────────────────────────────────────────────────
    // 7. AC 1: Dues and fees are hidden / denied via RLS, guardian contacts hidden
    // ─────────────────────────────────────────────────────────────────────────
    // Student navigation must NOT have Fee or Dues link
    await expect(page.locator('a[href="/portal/fees"]')).not.toBeVisible();
    await expect(page.locator('text=Fees')).not.toBeVisible();

    // Create a student authenticated client to test RLS directly
    const studentClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    const { error: studentLoginErr } = await studentClient.auth.signInWithPassword({
      email: bilalAccount.auth_email,
      password: newStudentPassword,
    });
    expect(studentLoginErr).toBeNull();

    // AC 1: fee_challan query must return 0 rows for student
    const { data: studentFees } = await studentClient.from('fee_challan').select('*');
    expect(studentFees?.length ?? 0).toBe(0);

    // AC 1: student_guardian query must return 0 rows
    const { data: studentGuardians } = await studentClient.from('student_guardian').select('*');
    expect(studentGuardians?.length ?? 0).toBe(0);

    // ─────────────────────────────────────────────────────────────────────────
    // 8. AC 2: Student can only see own marks. When show_rank disabled, rank is hidden
    // ─────────────────────────────────────────────────────────────────────────
    await page.goto('/student/results');
    await expect(page.locator('text=Academic Results')).toBeVisible();

    // Student sees own mark (95) and subject
    await expect(page.locator('text=English Language')).toBeVisible();
    await expect(page.getByRole('cell', { name: '95', exact: true })).toBeVisible();

    // Student DOES NOT see peer marks (82)
    await expect(page.getByRole('cell', { name: '82', exact: true })).not.toBeVisible();
    await expect(page.locator('text=Zainab Peer')).not.toBeVisible();

    // When show_rank is disabled (default in policy), Class Rank card is hidden
    await expect(page.locator('text=Class Rank')).not.toBeVisible();

    // Direct RLS check: result_position returns 0 rows
    const { data: studentPositionsNoRank } = await studentClient.from('result_position').select('*');
    expect(studentPositionsNoRank?.length ?? 0).toBe(0);

    // Enable show_rank = true in policy
    await db
      .from('campus_portal_policy')
      .update({ show_rank: true })
      .eq('campus_id', campus!.id);

    // Reload results page
    await page.reload();
    await expect(page.locator('text=Academic Results')).toBeVisible();

    // Now Class Rank card is visible showing own rank (#1)
    await expect(page.locator('text=Class Rank')).toBeVisible();
    await expect(page.locator('text=#1')).toBeVisible();

    // Peer rank (#2) is still hidden
    await expect(page.locator('text=#2')).not.toBeVisible();

    // ─────────────────────────────────────────────────────────────────────────
    // 9. AC 3: Transfer Certificate issuance deprovisions student portal account
    // ─────────────────────────────────────────────────────────────────────────
    // Create TC certificate template
    const { data: template } = await db
      .from('certificate_template')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        certificate_type: 'transfer',
        language: 'en',
        version: 1,
        title: 'Transfer Certificate',
        body_html: '<p>Student transferred</p>',
        merge_field_whitelist: [],
        page_size: 'A4',
        status: 'draft',
      })
      .select('id')
      .single();

    // Issue Transfer Certificate for Bilal
    await db.from('certificate_issue').insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      student_id: studentId,
      enrolment_id: enrolmentId,
      session_id: session!.id,
      certificate_type: 'transfer',
      serial_no: `TC-${runId}-001`,
      template_id: template!.id,
      template_version: 1,
      language: 'en',
      status: 'issued',
      pdf_path: `tc-${runId}.pdf`,
      payload_snapshot: { reason: 'Relocation' },
    });

    // Run deprovision job
    const { data: deprovCount } = await db.rpc('deprovision_on_tc');
    expect(deprovCount).toBeGreaterThanOrEqual(1);

    // Account is now disabled
    const { data: updatedSpa } = await db
      .from('student_portal_account')
      .select('status')
      .eq('student_id', studentId)
      .single();
    expect(updatedSpa!.status).toBe('disabled');

    // Student visits portal after TC: rendered "Portal Access Unavailable"
    await page.goto('/student/timetable');
    await expect(page.locator('text=Portal Access Unavailable')).toBeVisible();
    await expect(
      page.locator('text=Your student portal account is inactive or has been deprovisioned')
    ).toBeVisible();

    // Guardian retains archived read access
    const guardianClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await guardianClient.auth.signInWithPassword({ email: parentEmail, password: DEFAULT_STAFF_PW });
    const { data: guardianChildView } = await guardianClient
      .from('student')
      .select('id, name_en')
      .eq('id', studentId);
    expect(guardianChildView?.length).toBe(1);
    expect(guardianChildView?.[0]?.id).toBe(studentId);
  });
});
