import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

async function seedTenantWithOwner() {
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const slug = `public-enquiry-e2e-${runId}`;
  const email = `owner-${runId}@public-enquiry-e2e.test`;
  const password = 'e2e-test-password-123!';

  const { data: tenantId, error: e1 } = await admin.rpc('provision_tenant', {
    p_slug: slug,
    p_legal_name: `Public Enquiry E2E School ${runId}`,
    p_owner_email: email,
  });
  if (e1) throw e1;
  const { data: created, error: e2 } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (e2 || !created.user) throw e2 ?? new Error('user creation failed');
  const { error: e3 } = await admin
    .from('app_user')
    .insert({ user_id: created.user.id, tenant_id: tenantId as string, app_role: 'owner', full_name: 'E2E Owner' });
  if (e3) throw e3;

  return { slug, email, password };
}

test('a visitor submits a public enquiry in Urdu, and it appears live on the staff admissions queue', async ({ browser }) => {
  const { slug, email, password } = await seedTenantWithOwner();

  // The staff side opens the enquiries queue first — the realtime
  // subscription is live before the public submission happens.
  const staffContext = await browser.newContext();
  const staffPage = await staffContext.newPage();
  await staffPage.goto('/login');
  await staffPage.waitForLoadState('networkidle');
  await staffPage.getByLabel('Email').fill(email);
  await staffPage.getByLabel('Password').fill(password);
  await staffPage.getByRole('button', { name: 'Sign in' }).click();
  await expect(staffPage).toHaveURL(/\/campuses$/);
  await staffPage.goto('/admissions/enquiries');
  await staffPage.waitForLoadState('networkidle');
  // The realtime subscription's auth handshake is async — wait for it to
  // actually reach SUBSCRIBED before triggering the public submission, so
  // the 5-second budget below measures real delivery latency, not a cold
  // start race.
  await expect(staffPage.getByTestId('realtime-status')).toHaveAttribute('data-status', 'SUBSCRIBED', { timeout: 10_000 });

  // A fully separate, unauthenticated browser context for the public
  // visitor — no cookies, no session, exactly like a stranger on the
  // school's website.
  const publicContext = await browser.newContext();
  const publicPage = await publicContext.newPage();
  await publicPage.goto(`/apply/${slug}`);
  await publicPage.waitForLoadState('networkidle');
  await expect(publicPage.getByTestId('public-apply-card')).toBeVisible();

  // AC: the Urdu locale accepts Urdu script and renders the confirmation
  // right-to-left.
  await publicPage.getByTestId('locale-toggle').click();
  await publicPage.getByLabel('بچے کا نام', { exact: true }).fill('ویب چائلڈ');
  await publicPage.getByTestId('child-name-ur').fill('ویب چائلڈ اردو');
  await publicPage.getByLabel('تاریخ پیدائش').fill('2020-01-01');
  await publicPage.getByLabel('والدین کا نام').fill('ویب پیرنٹ');
  await publicPage.getByLabel('فون نمبر').fill('03001234567');
  await publicPage.getByRole('button', { name: 'انکوائری جمع کروائیں' }).click();

  const confirmation = publicPage.getByTestId('enquiry-confirmation');
  await expect(confirmation).toBeVisible();
  await expect(confirmation).toHaveAttribute('dir', 'rtl');
  const enquiryNo = await publicPage.getByTestId('enquiry-no').textContent();
  expect(enquiryNo).toBeTruthy();

  // AC: it appears in the campus admissions queue within 5 seconds over
  // Realtime — no manual reload on the staff page.
  await expect(staffPage.getByText(enquiryNo!)).toBeVisible({ timeout: 5_000 });
  await expect(staffPage.getByText('ویب چائلڈ')).toBeVisible();

  await staffContext.close();
  await publicContext.close();
});

test('an unknown school slug is refused with a real HTTP 404, and a 6th rapid submission from the same phone is refused with 429', async ({
  page,
}) => {
  const { slug } = await seedTenantWithOwner();

  const notFoundResponse = await page.request.post('/api/public-enquiry/no-such-school-xyz', {
    data: { childName: 'X', dob: '2020-01-01', classCode: '1', parentName: 'Y', phone: '03001234567' },
  });
  expect(notFoundResponse.status()).toBe(404);

  // Randomized per run — a fixed literal would collide with the same
  // phone number's rate-limit counter left over from an earlier run
  // against this same local database.
  const phone = `0300${Math.floor(1000000 + Math.random() * 8999999)}`;
  for (let i = 0; i < 5; i++) {
    const response = await page.request.post(`/api/public-enquiry/${slug}`, {
      data: { childName: `Sib ${i}`, dob: `2020-01-0${i + 1}`, classCode: '1', parentName: 'Rate Parent', phone },
    });
    expect(response.status()).toBe(200);
  }
  const sixthResponse = await page.request.post(`/api/public-enquiry/${slug}`, {
    data: { childName: 'Sib 6', dob: '2020-01-06', classCode: '1', parentName: 'Rate Parent', phone },
  });
  expect(sixthResponse.status()).toBe(429);
});
