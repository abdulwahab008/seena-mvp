import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

// FR-N01: Guardian portal access claim.
// Acceptance Criteria:
// 1. 3 failed GR+CNIC combinations from one device in 10 minutes lock the 4th attempt out.
// 2. A valid claim issues a short-lived, single-use OTP to the phone on file.
// 3. A guardian who cannot receive the code is queued for the office (never self-enters a number).
// 4. A successful claim links only the claimed student.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const SUPABASE_ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const STAFF_PW = 'e2e-test-password-123!';

// [auth.sms.test_otp] fixture in supabase/config.toml dedicated to the claim specs.
const TEST_PHONE = '923005551299';
const TEST_PHONE_E164 = '+923005551299';
const TEST_CODE = '654321';
const NOT_FOUND = 'We could not match those details. Check them and try again.';

async function seed() {
  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data: existing } = await db.auth.admin.listUsers();
  const stale = existing?.users.find((u) => u.phone === TEST_PHONE);
  if (stale) await db.auth.admin.deleteUser(stale.id);

  const runId = randomUUID().slice(0, 8);
  const email = `principal-${runId}@claim-e2e.test`;
  const slug = `claim-e2e-${runId}`;
  const { data: tenantId, error: provError } = await db.rpc('provision_tenant', { p_slug: slug, p_legal_name: `Claim E2E ${runId}`, p_owner_email: email });
  if (provError) throw provError;
  const tenant = tenantId as string;

  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  const { data: staff } = await db.auth.admin.createUser({ email, password: STAFF_PW, email_confirm: true });
  await db.from('app_user').insert({ user_id: staff.user!.id, tenant_id: tenant, app_role: 'principal', full_name: 'Principal' });
  await db.from('user_campus').insert({ user_id: staff.user!.id, tenant_id: tenant, campus_id: campus!.id });

  const staffClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false } });
  await staffClient.auth.signInWithPassword({ email, password: STAFF_PW });

  const { data: studentId, error: se } = await staffClient.rpc('create_student', { p_campus_id: campus!.id, p_name_en: 'Claim Kid', p_dob: '2015-03-03', p_gender: 'male' });
  if (se) throw se;
  const { data: student } = await db.from('student').select('gr_number').eq('id', studentId as string).single();

  const { data: guardian, error: ge } = await db
    .from('guardian')
    .insert({ tenant_id: tenant, name_en: 'Claim Parent', cnic: '35202-1234567-1', phone_e164: TEST_PHONE_E164 })
    .select('id')
    .single();
  if (ge) throw ge;
  const { error: le } = await db.from('student_guardian').insert({ tenant_id: tenant, student_id: studentId as string, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });
  if (le) throw le;

  return { slug, gr: student!.gr_number as string, cnicTail: '345671' };
}

test.describe('FR-N01: guardian portal access claim', () => {
  test('never discloses which half was wrong, locks the 4th attempt, then a valid claim activates via OTP with a masked phone', async ({ browser }) => {
    test.setTimeout(90000);
    const { slug, gr, cnicTail } = await seed();

    const lockedOut = await browser.newContext();
    const page = await lockedOut.newPage();

    async function submit(school: string, grNumber: string, cnic: string) {
      await page.goto('/guardian/claim');
      await page.waitForLoadState('networkidle');
      await page.getByLabel('School code').fill(school);
      await page.getByLabel(/GR number/).fill(grNumber);
      await page.getByLabel(/last 6 digits/i).fill(cnic);
      await page.getByTestId('claim-submit').click();
    }

    await submit(slug, gr, '000000');
    await expect(page.getByTestId('claim-error')).toHaveText(NOT_FOUND);
    await submit(slug, '9999999', cnicTail);
    await expect(page.getByTestId('claim-error')).toHaveText(NOT_FOUND);
    await submit('no-such-school-xyz', gr, cnicTail);
    await expect(page.getByTestId('claim-error')).toHaveText(NOT_FOUND);

    // 4th attempt from the same device is refused even with correct details.
    await submit(slug, gr, cnicTail);
    await expect(page.getByTestId('claim-error')).toHaveText('Too many attempts. Try again in 30 minutes.');
    await lockedOut.close();

    // A different device with the right details gets through to activation.
    const fresh = await browser.newContext();
    const p2 = await fresh.newPage();
    await p2.goto('/guardian/claim');
    await p2.waitForLoadState('networkidle');
    await p2.getByLabel('School code').fill(slug);
    await p2.getByLabel(/GR number/).fill(gr);
    await p2.getByLabel(/last 6 digits/i).fill(cnicTail);
    await p2.getByTestId('claim-submit').click();
    await expect(p2).toHaveURL(/\/guardian\/activate\//);

    await expect(p2.getByText(TEST_PHONE_E164)).toHaveCount(0);
    await expect(p2.getByText(/\+92\*+99/)).toBeVisible();

    await p2.getByTestId('activate-request-code').click();
    await expect(p2.getByText(/Code sent to \+92\*+99/)).toBeVisible();
    await p2.getByLabel('6-digit code').fill('000000');
    await p2.getByTestId('activate-verify-code').click();
    await expect(p2.getByText('Incorrect or expired code.')).toBeVisible();
    await p2.getByLabel('6-digit code').fill(TEST_CODE);
    await p2.getByTestId('activate-verify-code').click();
    await expect(p2).toHaveURL(/\/portal\/homework$/);

    await p2.goto('/portal/link-child');
    await expect(p2.getByRole('heading', { name: 'Add another child' })).toBeVisible();
    await fresh.close();
  });
});
