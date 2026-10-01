import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S08: request -> background build -> notification -> download -> dedupe -> retention (410).

const SECRET = process.env.EXPORT_WORKER_SECRET!;
const runWorker = (request: import('@playwright/test').APIRequestContext) => request.post('/api/internal/exports/run', { headers: { 'x-worker-secret': SECRET } });

test('the worker routes reject calls without the secret', async ({ request }) => {
  expect((await request.post('/api/internal/exports/run')).status()).toBe(401);
  expect((await request.post('/api/internal/exports/run', { headers: { 'x-worker-secret': 'wrong-secret-wrong-secret' } })).status()).toBe(401);
  expect((await request.post('/api/internal/exports/purge')).status()).toBe(401);
});

test('a student export is queued, built in the background, notified, downloadable, deduplicated and purged', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, email, tenant, owner$ } = await seedFeesTenant(3, 'export-e2e');
  const { data: me } = await owner$.auth.getUser();

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/reports/exports');
  await page.waitForLoadState('networkidle');
  await page.locator('#datasetKey').selectOption('students');
  await page.getByRole('button', { name: 'Request Excel export' }).click();
  await expect(page.getByText('This export contains personal data')).toBeVisible();

  await page.locator('#reason').fill('Board registration paperwork for the new session');
  await page.getByRole('button', { name: 'Request Excel export' }).click();
  await expect(page.getByText('Export queued')).toBeVisible();

  // The worker may already have been nudged; make sure it has run, then see the result.
  await expect.poll(async () => (await runWorker(request)).status()).toBe(200);
  await page.reload();
  await expect(page.getByTestId('export-job').first()).toContainText('done', { timeout: 30000 });
  await expect(page.getByTestId('notifications')).toContainText('Your export is ready');
  await expect(page.getByTestId('export-job').first()).toContainText('3 rows');

  const link = await page.getByTestId('export-download').first().getAttribute('href');
  const file = await page.request.get(link!);
  expect(file.status()).toBe(200);
  expect(file.headers()['content-type']).toContain('spreadsheetml');
  const body = await file.body();
  expect(body.subarray(0, 2).toString()).toBe('PK');

  // Identical request within 60 s: same job, no second file.
  await page.locator('#datasetKey').selectOption('students');
  await page.locator('#reason').fill('Board registration paperwork for the new session');
  await page.getByRole('button', { name: 'Request Excel export' }).click();
  await expect(page.getByText('already being prepared')).toBeVisible();
  const { count } = await db.from('report_export_job').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant).eq('requested_by', me.user!.id);
  expect(count).toBe(1);

  // Retention: past expiry the purge removes the file and the link answers 410.
  const { data: job } = await db.from('report_export_job').select('id').eq('tenant_id', tenant).single();
  await db.from('report_export_job').update({ expires_at: new Date(Date.now() - 86400_000).toISOString() }).eq('id', job!.id);
  const purge = await request.post('/api/internal/exports/purge', { headers: { 'x-worker-secret': SECRET } });
  expect(purge.status()).toBe(200);
  expect((await purge.json()).purged).toBeGreaterThanOrEqual(1);
  const gone = await page.request.get(link!);
  expect(gone.status()).toBe(410);
});

test('45,000 rows build in the background in well under 3 minutes', async ({ request }) => {
  test.setTimeout(240000);
  const { db, tenant, campusId, challans, owner$ } = await seedFeesTenant(1, 'export-big');
  const enrolId = challans[0]!.enrolment_id;
  const today = new Date().toISOString().slice(0, 10);

  for (let c = 0; c < 9; c++) {
    const rows = Array.from({ length: 5000 }, (_, i) => ({ tenant_id: tenant, campus_id: campusId, enrolment_id: enrolId, amount_paisa: 100 + i, mode: 'cash', value_date: today, reference_no: `bulk-${c}-${i}` }));
    const { error } = await db.from('fee_payment').insert(rows);
    expect(error).toBeNull();
  }

  const { data: req, error } = await owner$.rpc('request_report_export', { p_dataset_key: 'fee_collection', p_params: {} });
  expect(error).toBeNull();
  const jobId = (req as { job_id: string }).job_id;

  const started = Date.now();
  const res = await request.post('/api/internal/exports/run', { headers: { 'x-worker-secret': SECRET }, timeout: 200000 });
  expect(res.status()).toBe(200);
  // Jobs are a shared queue: another test's worker call may be the one building ours.
  await expect.poll(async () => (await db.from('report_export_job').select('status').eq('id', jobId).single()).data?.status, { timeout: 170_000, intervals: [2000] }).toBe('done');
  const { data: job } = await db.from('report_export_job').select('status, row_count, storage_path').eq('id', jobId).single();
  expect(job?.status).toBe('done');
  expect(job?.row_count).toBe(45000);
  expect(Date.now() - started).toBeLessThan(180_000);
  const { data: blob } = await db.storage.from('report_exports').download(job!.storage_path!);
  expect(blob!.size).toBeGreaterThan(1_000_000);
});
