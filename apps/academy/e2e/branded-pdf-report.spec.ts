import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S09: set a campus address, request a report as PDF, the worker renders it on
// letterhead, and the download is a real PDF.

const SECRET = process.env.EXPORT_WORKER_SECRET!;

test('an owner prints the fee collection report as a PDF on campus letterhead', async ({ page, request }) => {
  test.setTimeout(180000);
  const { db, email, tenant, challans, owner$ } = await seedFeesTenant(3, 'pdf-e2e');
  expect(challans.length).toBeGreaterThan(0);
  const { data: enrol } = await db.from('fee_challan').select('enrolment_id').eq('tenant_id', tenant).limit(1).single();
  const paid = await owner$.rpc('record_payment', { p_enrolment_id: enrol!.enrolment_id, p_amount_paisa: 500000, p_mode: 'cash', p_reference_no: 'pdf-e2e-1', p_value_date: new Date().toISOString().slice(0, 10) });
  expect(paid.error).toBeNull();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/branding');
  await page.getByLabel('Address (English)').first().fill('12 Canal Road, Lahore');
  await page.getByTestId('save-address').first().click();
  await expect.poll(async () => (await db.from('campus_branding').select('address_en').eq('tenant_id', tenant)).data?.[0]?.address_en).toBe('12 Canal Road, Lahore');

  await page.goto('/reports/exports');
  await page.waitForLoadState('networkidle');
  await page.locator('#datasetKey').selectOption('fee_collection');
  await page.getByTestId('request-pdf').click();
  await expect(page.getByText('Export queued')).toBeVisible();

  await expect.poll(async () => (await request.post('/api/internal/exports/run', { headers: { 'x-worker-secret': SECRET } })).status()).toBe(200);
  await page.reload();
  await expect(page.getByTestId('export-job').first()).toContainText('PDF');
  await expect(page.getByTestId('export-job').first()).toContainText('done', { timeout: 60000 });

  const link = await page.getByTestId('export-download').first().getAttribute('href');
  const file = await page.request.get(link!);
  expect(file.status()).toBe(200);
  expect(file.headers()['content-type']).toContain('application/pdf');
  expect((await file.body()).subarray(0, 5).toString()).toBe('%PDF-');
});
