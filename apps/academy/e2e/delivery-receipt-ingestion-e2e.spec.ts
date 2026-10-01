import { test, expect } from '@playwright/test';
import { seedSchoolOwner } from './support/school-owner-seed';
import crypto from 'crypto';

test.describe('FR-M09: Delivery Receipt Ingestion & Monotonic State Machine', () => {
  const WEBHOOK_SECRET = process.env.COMM_WEBHOOK_SECRET!;

  test('AC 2: Webhook endpoint rejects missing or invalid HMAC signature with HTTP 401', async ({ request }) => {
    // 1. Missing signature
    const resNoSig = await request.post('/api/webhooks/comm/sms', {
      data: { provider_ref: 'TEST-SIG-1', status: 'delivered' },
    });
    expect(resNoSig.status()).toBe(401);

    // 2. Tampered / invalid signature
    const resBadSig = await request.post('/api/webhooks/comm/sms', {
      data: { provider_ref: 'TEST-SIG-2', status: 'delivered' },
      headers: {
        'x-comm-signature': 'invalid-tampered-hmac-signature-hex',
      },
    });
    expect(resBadSig.status()).toBe(401);

    // 3. Valid signature
    const payload = JSON.stringify({ provider_ref: 'WEBHOOK-VALID-REF-99', status: 'delivered' });
    const validHmac = crypto.createHmac('sha256', WEBHOOK_SECRET).update(payload, 'utf8').digest('hex');

    const resValidSig = await request.post('/api/webhooks/comm/sms', {
      data: Buffer.from(payload, 'utf8'),
      headers: {
        'content-type': 'application/json',
        'x-comm-signature': validHmac,
      },
    });
    expect(resValidSig.status()).toBe(200);
    const json = await resValidSig.json();
    expect(json.ok).toBe(true);
  });

  test('Principal / Owner manages delivery receipts, monitors stats, tests dead-letter and stale sweeper', async ({
    page,
  }) => {
    // 1. Sign in as Owner
    const owner = await seedSchoolOwner('delivery-receipt');
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.getByLabel('Email').fill(owner.email);
    await page.getByLabel('Password').fill(owner.password);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await expect(page).toHaveURL(/\/dashboard/);

    // 2. Navigate to Delivery Receipts desk
    await page.goto('/communication/receipts');
    await page.waitForLoadState('networkidle');

    // 3. Verify page title and KPI cards
    await expect(page.locator('h1')).toContainText('Delivery Receipt Ingestion & Analytics');
    await expect(page.getByText('Overall Delivery Rate')).toBeVisible();
    await expect(page.getByText('Total Dispatched')).toBeVisible();
    await expect(page.getByText('Expired (Unreached)')).toBeVisible();
    await expect(page.getByText('Dead-Letter Count')).toBeVisible();

    // 4. Test AC 3: Ingest unmatched provider ref to populate Dead-Letter Queue
    const deadLetterRef = `UNMATCHED-DLR-${Date.now()}`;
    await page.getByPlaceholder('e.g. PROV-REF-1234').fill(deadLetterRef);
    await page.getByRole('button', { name: 'Apply Receipt' }).click();

    // Expect success notice
    await expect(page.getByText(/Receipt processed/i)).toBeVisible({ timeout: 10000 });

    // Open Dead-Letter Queue tab and verify record exists
    await page.getByRole('button', { name: /Dead-Letter Queue/i }).click();
    await expect(page.getByRole('cell', { name: deadLetterRef, exact: true })).toBeVisible();
    await expect(page.getByText('attempt_not_found').first()).toBeVisible();

    // 5. Test AC 4: Trigger Stale Sweeper
    await page.getByRole('button', { name: 'Run Stale Sweeper (24h)' }).click();
    await expect(page.getByText(/Stale sweeper completed/i)).toBeVisible({ timeout: 10000 });

    // 6. Verify Recent Receipts Log tab
    await page.getByRole('button', { name: /Recent Receipts Log/i }).click();
    await expect(page.getByRole('main').getByText(/Recent Receipts Log/i)).toBeVisible();
  });
});
