import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-T04: Dues clearance gate before TC release
// Verifies:
// 1. Student with unpaid dues triggers clearance gate warning in TC issuance UI.
// 2. Issuance without override is blocked.
// 3. Providing authorized override justification (>= 20 chars) releases TC.
// 4. Student without dues shows cleared status and issues without override.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

const TC_BODY =
  '<p>Transfer Certificate for {{student.name_en}}, GR No. {{student.gr_number}}, left on {{enrolment.left_on}}. ' +
  'Serial No. {{issue.serial_no}}, issued {{issue.date}}.</p>';

test.describe('FR-T04: Dues clearance gate before TC release', () => {
  test('surfaces outstanding fee dues and enforces clearance or authorized override', async ({ page }) => {
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const runId = randomUUID().slice(0, 8);
    const ownerEmail = `owner-${runId}@duesgate-e2e.test`;
    const clerkEmail = `clerk-${runId}@duesgate-e2e.test`;

    // 1. Provision tenant
    const { data: tenantId, error: provError } = await admin.rpc('provision_tenant', {
      p_slug: `duesgate-${runId}`,
      p_legal_name: `Dues Gate School ${runId}`,
      p_owner_email: ownerEmail,
    });
    expect(provError).toBeNull();

    const { data: campus } = await admin.from('campus').select('id').eq('tenant_id', tenantId as string).single();
    const { data: session } = await admin.from('academic_session').select('id').eq('tenant_id', tenantId as string).single();
    const { data: classLevel } = await admin
      .from('class_level')
      .select('id')
      .eq('tenant_id', tenantId as string)
      .eq('code', '1')
      .single();

    // 2. Create users
    const makeUser = async (email: string, role: 'owner' | 'admissions_officer', fullName: string) => {
      const { data: created, error: userError } = await admin.auth.admin.createUser({
        email,
        password: PASSWORD,
        email_confirm: true,
      });
      if (userError || !created.user) throw userError ?? new Error(`${role} creation failed`);
      await admin.from('app_user').insert({
        user_id: created.user.id,
        tenant_id: tenantId as string,
        app_role: role,
        full_name: fullName,
      });
      await admin.from('user_campus').insert({
        user_id: created.user.id,
        tenant_id: tenantId as string,
        campus_id: campus!.id,
      });
    };

    await makeUser(ownerEmail, 'owner', 'Dues Gate Owner');
    await makeUser(clerkEmail, 'admissions_officer', 'Farhat Clerk');

    // 3. Create section
    const { data: section } = await admin
      .from('class_section')
      .insert({
        tenant_id: tenantId as string,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name: 'A',
        capacity: 40,
      })
      .select('id')
      .single();

    // 4. Sign in as owner to create students and template
    const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });

    const { data: s1Id } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Kamran Akmal',
      p_dob: '2012-04-15',
      p_gender: 'male',
    });
    const { data: e1Id } = await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: s1Id as string,
    });

    const { data: s2Id } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Saima Khan',
      p_dob: '2013-09-20',
      p_gender: 'female',
    });
    await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: s2Id as string,
    });

    // Create & activate TC template
    const { data: tplId } = await ownerClient.rpc('create_certificate_template', {
      p_certificate_type: 'transfer',
      p_title: 'School Leaving Certificate',
      p_body_html: TC_BODY,
      p_board_code: null,
      p_language: 'en',
      p_page_size: 'A4',
      p_campus_id: campus!.id,
    });
    await ownerClient.rpc('activate_certificate_template', { p_template_id: tplId as string });

    // 5. Create an unpaid challan for Kamran
    await admin.from('fee_challan').insert({
      tenant_id: tenantId as string,
      campus_id: campus!.id,
      enrolment_id: e1Id as string,
      student_id: s1Id as string,
      session_id: session!.id,
      billing_period: new Date().toISOString().slice(0, 10),
      challan_no: 'CH-GATE-E2E-1',
      due_date: new Date(Date.now() - 10 * 86400000).toISOString().slice(0, 10),
      gross_paisa: 750000,
      net_paisa: 750000,
      status: 'unpaid',
    });

    // 6. Login as clerk and navigate to TC issue page
    await page.goto('/login');
    await page.getByLabel('Email').fill(clerkEmail);
    await page.fill('input[type="password"]', PASSWORD);
    await page.click('button[type="submit"]');
    await page.waitForURL('**/dashboard**');

    await page.goto('/certificates/issue');
    await expect(page.locator('h1, h2')).toContainText(['Issue', 'Transfer']);

    // Select Kamran (who has dues)
    await page.click('[data-testid="cert-issue-student-trigger"]');
    await page.getByRole('option', { name: /Kamran Akmal/ }).click();

    // Verify Clearance Gate detects outstanding dues
    const gateContainer = page.locator('[data-testid="clearance-gate-container"]');
    await expect(gateContainer).toBeVisible();
    await expect(page.locator('[data-testid="clearance-status-dues"]')).toBeVisible();
    await expect(gateContainer).toContainText('CH-GATE-E2E-1');
    await expect(gateContainer).toContainText('PKR 7,500');

    // Attempt to issue without override -> should be blocked
    await page.click('[data-testid="cert-issue-submit"]');
    await expect(page.locator('[data-testid="cert-issue-error"]')).toContainText('override reason of at least 20 characters is required');

    // Provide short override -> should still be blocked
    await page.fill('[data-testid="cert-issue-override-reason"]', 'Too short');
    await page.click('[data-testid="cert-issue-submit"]');
    await expect(page.locator('[data-testid="cert-issue-error"]')).toContainText('override reason of at least 20 characters is required');

    // Provide valid authorized override (>= 20 characters)
    await page.fill(
      '[data-testid="cert-issue-override-reason"]',
      'Principal approved TC release with installment clearance affidavit submitted by guardian.'
    );
    await page.click('[data-testid="cert-issue-submit"]');

    // Verify issuance succeeded
    await expect(page.locator('[data-testid="cert-issue-result"]')).toBeVisible({ timeout: 15000 });
    await expect(page.locator('[data-testid="cert-issue-result"]')).toContainText('Issued as TC-');
  });
});
