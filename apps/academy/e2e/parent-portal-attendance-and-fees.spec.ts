import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-N03: Child attendance view (/portal/attendance)
// FR-N04: Fee dues view & payment action (/portal/fees)
//
// Verifies:
// 1. Parent can access /portal/attendance and view multi-child attendance stats & daily logs.
// 2. Parent can access /portal/fees and view outstanding balance, challans, slip modal, and online payment instructions.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

test.describe('FR-N03 & FR-N04: Parent Portal Attendance and Fees', () => {
  test('parent views attendance records and fee dues with challan modal', async ({ page }) => {
    const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const runId = randomUUID().slice(0, 8);
    const ownerEmail = `owner-${runId}@portal-e2e.test`;
    const parentEmail = `parent-${runId}@portal-e2e.test`;

    // 1. Provision tenant
    const { data: tenantId, error: provError } = await db.rpc('provision_tenant', {
      p_slug: `portal-e2e-${runId}`,
      p_legal_name: `Portal E2E School ${runId}`,
      p_owner_email: ownerEmail,
    });
    expect(provError).toBeNull();
    const tenant = tenantId as string;

    const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
    const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
    const { data: classLevel } = await db
      .from('class_level')
      .select('id')
      .eq('tenant_id', tenant)
      .eq('code', '1')
      .single();

    // 2. Create users
    const { data: ownerUser } = await db.auth.admin.createUser({
      email: ownerEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    await db.from('app_user').insert({
      user_id: ownerUser.user!.id,
      tenant_id: tenant,
      app_role: 'owner',
      full_name: 'Portal Owner',
    });
    await db.from('user_campus').insert({
      user_id: ownerUser.user!.id,
      tenant_id: tenant,
      campus_id: campus!.id,
    });

    const { data: parentUser } = await db.auth.admin.createUser({
      email: parentEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    await db.from('app_user').insert({
      user_id: parentUser.user!.id,
      tenant_id: tenant,
      app_role: 'parent',
      full_name: 'Sadia Parent',
    });

    // 3. Create section
    const { data: section } = await db
      .from('class_section')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name: 'A',
        capacity: 40,
      })
      .select('id')
      .single();

    // 4. Create student & link to parent
    const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });

    const { data: sId } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Hamza Farooq',
      p_dob: '2014-06-12',
      p_gender: 'male',
    });
    const studentId = sId as string;

    const { data: eId } = await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId,
    });
    const enrolmentId = eId as string;

    const { data: gId } = await ownerClient.rpc('create_guardian', {
      p_name_en: 'Sadia Farooq',
      p_phone: '03009988776',
    });
    const guardianId = gId as string;

    await ownerClient.rpc('link_guardian', {
      p_student_id: studentId,
      p_guardian_id: guardianId,
      p_relationship: 'mother',
      p_is_primary: true,
      p_may_collect_child: true,
      p_receives_academic: true,
      p_receives_billing: true,
    });

    await db.from('guardian').update({ auth_user_id: parentUser.user!.id }).eq('id', guardianId);

    // 5. Create attendance record for Hamza
    const today = new Date().toISOString().slice(0, 10);
    await db.from('attendance_day').insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      session_id: session!.id,
      enrolment_id: enrolmentId,
      attendance_date: today,
      status: 'present',
      time_in: '07:55:00',
    });

    // 6. Create fee challan for Hamza
    await db.from('fee_challan').insert({
      tenant_id: tenant,
      campus_id: campus!.id,
      enrolment_id: enrolmentId,
      student_id: studentId,
      session_id: session!.id,
      billing_period: today,
      challan_no: 'CH-PORTAL-E2E-1',
      due_date: new Date(Date.now() + 10 * 86400000).toISOString().slice(0, 10),
      gross_paisa: 600000,
      net_paisa: 600000,
      status: 'unpaid',
    });

    // 7. Login as parent
    await page.goto('/login');
    await page.fill('input[type="email"]', parentEmail);
    await page.fill('input[type="password"]', PASSWORD);
    await page.click('button[type="submit"]');
    await page.waitForURL('**/portal**');

    // 8. Test Attendance Page (FR-N03)
    await page.goto('/portal/attendance');
    await expect(page.locator('h1')).toContainText('Attendance');
    await expect(page.locator('[data-testid="attendance-kpi-cards"]')).toBeVisible();
    await expect(page.locator('[data-testid="attendance-log-table"]')).toBeVisible();
    await expect(page.locator('[data-testid="attendance-log-table"]')).toContainText('Present');

    // 9. Test Fees Page (FR-N04)
    await page.goto('/portal/fees');
    await expect(page.locator('h1')).toContainText('Fee Dues & Challans');
    await expect(page.locator('[data-testid="fees-dues-banner"]')).toBeVisible();
    await expect(page.locator('[data-testid="fees-dues-banner"]')).toContainText('PKR 6,000');
    await expect(page.locator('[data-testid="challan-card-CH-PORTAL-E2E-1"]')).toBeVisible();

    // Open Challan Slip Modal
    await page.click('[data-testid="btn-view-challan-CH-PORTAL-E2E-1"]');
    await expect(page.locator('[data-testid="challan-slip-modal"]')).toBeVisible();
    await expect(page.locator('[data-testid="challan-slip-modal"]')).toContainText('CH-PORTAL-E2E-1');
    await expect(page.locator('[data-testid="challan-slip-modal"]')).toContainText('PKR 6,000');
    await page.click('[data-testid="btn-close-challan-slip"]');

    // Open Pay Online Modal
    await page.click('[data-testid="btn-pay-online-CH-PORTAL-E2E-1"]');
    await expect(page.locator('[data-testid="pay-online-modal"]')).toBeVisible();
    await expect(page.locator('[data-testid="pay-online-modal"]')).toContainText('CH-PORTAL-E2E-1');
    await expect(page.locator('[data-testid="pay-online-modal"]')).toContainText('1Link / 1Bill');
    await page.click('[data-testid="btn-close-pay-online"]');
  });
});
