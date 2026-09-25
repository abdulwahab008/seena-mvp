import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-N08: Moderated teacher remarks
// Acceptance Criteria:
// 1. Given approval is enabled and a teacher submits a remark, when the guardian loads the portal,
//    then the remark is absent until a Principal approves it, and approval makes it visible within 60 seconds.
// 2. Given an approved remark, when the teacher edits it, then a new version is created with status 'pending'
//    and the previously approved version remains the visible one until the edit is approved.
// 3. Given a remark is rejected, when the Principal saves the rejection, then the teacher is notified
//    with the rejection reason and the guardian never sees the text.
// 4. Given a remark written in Urdu, when a guardian views it, then it renders right-to-left
//    without clipping at a 360 px viewport width.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PASSWORD = 'e2e-test-password-123!';

test.describe('FR-N08: Moderated Teacher Remarks & Guardian Portal', () => {
  test('Complete remarks lifecycle: approval gating, versioning on edit, rejection feedback, and Urdu RTL rendering', async ({
    page,
  }) => {
    test.setTimeout(90000);
    const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const runId = randomUUID().slice(0, 8);
    const ownerEmail = `principal-${runId}@remarks-e2e.test`;
    const parentEmail = `parent-${runId}@remarks-e2e.test`;

    // 1. Provision tenant
    const { data: tenantId, error: provError } = await db.rpc('provision_tenant', {
      p_slug: `remarks-e2e-${runId}`,
      p_legal_name: `Remarks Academy ${runId}`,
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

    // 2. Create Principal / Staff user
    const { data: staffUser } = await db.auth.admin.createUser({
      email: ownerEmail,
      password: PASSWORD,
      email_confirm: true,
    });
    await db.from('app_user').insert({
      user_id: staffUser.user!.id,
      tenant_id: tenant,
      app_role: 'principal',
      full_name: 'Principal Ahmed',
    });
    await db.from('user_campus').insert({
      user_id: staffUser.user!.id,
      tenant_id: tenant,
      campus_id: campus!.id,
    });

    // 3. Create Parent user (Guardians exist in auth.users and guardian table, without an app_user row)
    const { data: parentUser } = await db.auth.admin.createUser({
      email: parentEmail,
      password: PASSWORD,
      email_confirm: true,
    });

    // 4. Create Section & Student
    const { data: section } = await db
      .from('class_section')
      .insert({
        tenant_id: tenant,
        campus_id: campus!.id,
        session_id: session!.id,
        class_level_id: classLevel!.id,
        name: 'A',
        capacity: 35,
      })
      .select('id')
      .single();

    const ownerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
    await ownerClient.auth.signInWithPassword({ email: ownerEmail, password: PASSWORD });

    const { data: sId } = await ownerClient.rpc('create_student', {
      p_campus_id: campus!.id,
      p_name_en: 'Ali Tariq',
      p_dob: '2016-03-20',
      p_gender: 'male',
    });
    const studentId = sId as string;

    await ownerClient.rpc('enrol_student', {
      p_section_id: section!.id,
      p_student_id: studentId,
    });

    const { data: guardian, error: gErr } = await db
      .from('guardian')
      .insert({
        tenant_id: tenant,
        name_en: 'Tariq Mehmood',
        phone_e164: '+923001234567',
        auth_user_id: parentUser.user!.id,
      })
      .select('id')
      .single();
    if (gErr) throw gErr;

    const { error: sgErr } = await db
      .from('student_guardian')
      .insert({
        tenant_id: tenant,
        student_id: studentId,
        guardian_id: guardian.id,
        relationship: 'father',
        is_primary: true,
        receives_academic: true,
        receives_billing: true,
      });
    if (sgErr) throw sgErr;

    // 5. Ensure campus portal policy has require_remark_approval = true
    await db.from('campus_portal_policy').upsert({
      campus_id: campus!.id,
      tenant_id: tenant,
      require_remark_approval: true,
    });

    const signInAs = async (email: string, targetPath: string) => {
      await page.context().clearCookies();
      await page.goto(`/login?redirectTo=${encodeURIComponent(targetPath)}`);
      await page.waitForLoadState('networkidle');
      await page.fill('input[type="email"]', email);
      await page.fill('input[type="password"]', PASSWORD);
      await page.click('button[type="submit"]');
      await page.waitForURL(`**${targetPath}**`);
    };

    // ── STEP 1: Teacher/Principal logs in and submits a remark ──
    await signInAs(ownerEmail, '/staff/remarks');

    // Navigate to Staff Remarks & Moderation desk
    await page.goto('/staff/remarks');
    await page.waitForLoadState('networkidle');
    await expect(page.locator('h1')).toContainText('Student Remarks & Moderation');

    // Compose remark
    await page.getByRole('button', { name: '+ Compose Remark' }).click();
    const remarkBody1 = 'Ali demonstrated great curiosity and improvement in mathematics this week.';
    await page.getByPlaceholder('Enter observation, feedback, or commendation...').fill(remarkBody1);
    await page.getByRole('button', { name: 'Submit for Moderation' }).click();

    // Verify remark shows in directory as pending
    await expect(page.getByText('All Remarks & History')).toBeVisible();
    await expect(page.getByText('pending').first()).toBeVisible();

    // ── STEP 2: Verify Remark is ABSENT from Guardian Portal before approval (AC 1) ──
    await signInAs(parentEmail, '/portal/remarks');
    await expect(page.getByRole('heading', { name: 'Teacher Remarks' })).toBeVisible();
    await expect(page.getByText('No teacher remarks have been published for your child yet.')).toBeVisible();
    await expect(page.getByText(remarkBody1)).not.toBeVisible();

    // ── STEP 3: Principal approves remark (AC 1) ──
    await signInAs(ownerEmail, '/staff/remarks');
    await page.getByRole('button', { name: /Moderation Queue/ }).click();
    await expect(page.getByText(remarkBody1)).toBeVisible();
    await page.getByRole('button', { name: 'Approve for Guardians' }).click();
    await expect(page.getByText('No pending remarks awaiting moderation.')).toBeVisible();

    // ── STEP 4: Guardian now sees the approved remark in Portal (AC 1) ──
    await signInAs(parentEmail, '/portal/remarks');
    await expect(page.getByText(remarkBody1)).toBeVisible();
    await expect(page.getByText('English')).toBeVisible();

    // ── STEP 5: Teacher edits remark -> creates new pending version, old version stays visible (AC 2) ──
    await signInAs(ownerEmail, '/staff/remarks');
    await page.getByRole('button', { name: 'All Remarks & History' }).click();
    await page.getByRole('button', { name: 'Edit / New Version' }).first().click();
    await expect(page.getByRole('heading', { name: 'Edit Remark (Create New Version)' })).toBeVisible();

    const remarkBody2 = 'Ali achieved top score in mathematics and assisted his peers enthusiastically.';
    await page.locator('textarea').fill(remarkBody2);
    await page.getByRole('button', { name: 'Save as New Version' }).click();
    await expect(page.getByRole('heading', { name: 'Edit Remark (Create New Version)' })).not.toBeVisible();

    // Guardian Portal must STILL show remarkBody1, NOT remarkBody2 (AC 2)
    await signInAs(parentEmail, '/portal/remarks');
    await expect(page.getByText(remarkBody1)).toBeVisible();
    await expect(page.getByText(remarkBody2)).not.toBeVisible();

    // ── STEP 6: Principal rejects version 2 with reason (AC 3) ──
    await signInAs(ownerEmail, '/staff/remarks');
    await page.getByRole('button', { name: /Moderation Queue/ }).click();
    await expect(page.getByText(remarkBody2)).toBeVisible();
    await page.getByRole('button', { name: 'Reject...' }).click();
    await expect(page.getByRole('heading', { name: 'Reject Remark' })).toBeVisible();

    const rejectReasonText = 'Please keep remarks concise and focus on individual progress.';
    await page.getByPlaceholder(/maintain positive developmental tone/).fill(rejectReasonText);
    await page.getByRole('button', { name: 'Confirm Rejection' }).click();
    await expect(page.getByRole('heading', { name: 'Reject Remark' })).not.toBeVisible();

    // Verify teacher sees feedback in directory
    await page.getByRole('button', { name: 'All Remarks & History' }).click();
    await expect(page.getByText(rejectReasonText)).toBeVisible();

    // ── STEP 7: Submit Urdu Remark and verify RTL at 360px viewport width (AC 4) ──
    await page.getByRole('button', { name: '+ Compose Remark' }).click();
    await page.getByLabel('اردو (Urdu)').check();
    const urduRemarkText = 'طالب علم نے اردو املا اور خوشخطی میں نمایاں پیش رفت کی ہے۔';
    await page.locator('textarea').fill(urduRemarkText);
    await page.getByRole('button', { name: 'Submit for Moderation' }).click();
    await expect(page.getByRole('heading', { name: 'Teacher Remarks Directory' })).toBeVisible();

    // Switch to Moderation Queue and approve
    await page.getByRole('button', { name: /Moderation Queue/ }).click();
    await expect(page.getByRole('heading', { name: 'Pending Approval Queue' })).toBeVisible();
    await expect(page.getByText(urduRemarkText)).toBeVisible();
    await page.getByRole('button', { name: 'Approve for Guardians' }).click();
    await expect(page.getByText('No pending remarks awaiting moderation.')).toBeVisible();

    // Switch to mobile viewport (360px) and view as Parent
    await page.setViewportSize({ width: 360, height: 640 });
    await signInAs(parentEmail, '/portal/remarks');

    await page.goto('/portal/remarks');
    await page.waitForLoadState('networkidle');

    // Verify Urdu remark rendered RTL without horizontal overflow / clipping
    const urduBlock = page.locator('div[dir="rtl"]', { hasText: urduRemarkText });
    await expect(urduBlock).toBeVisible();
    await expect(page.getByText('Urdu / اردو')).toBeVisible();

    // Check that card does not overflow 360px width
    const boundingBox = await urduBlock.boundingBox();
    expect(boundingBox).not.toBeNull();
    expect(boundingBox!.width).toBeLessThanOrEqual(360);
  });
});
