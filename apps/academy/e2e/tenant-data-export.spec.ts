import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-A19: the Owner exports the whole school; the archive has the CSVs (with a BOM) and a manifest;
// a Principal is refused; an expired link answers EXPORT_LINK_EXPIRED.

const SECRET = process.env.EXPORT_WORKER_SECRET!;

test('the owner exports all school data; a principal cannot; the link expires', async ({ page, browser, baseURL, request }) => {
  test.setTimeout(180000);
  const { db, email, tenant, campusId } = await seedFeesTenant(3, 'tenantexport-e2e');

  const principalEmail = `principal-${tenant.slice(0, 8)}@tenantexport-e2e.test`;
  const { data: p } = await db.auth.admin.createUser({ email: principalEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: p.user!.id, tenant_id: tenant, app_role: 'principal', full_name: 'Export Principal' });
  await db.from('user_campus').insert({ user_id: p.user!.id, tenant_id: tenant, campus_id: campusId });

  const signIn = async (pg: import('@playwright/test').Page, e: string) => {
    await pg.goto('/login');
    await pg.waitForLoadState('networkidle');
    await pg.getByLabel('Email').fill(e);
    await pg.getByLabel('Password').fill(SEED_PASSWORD);
    await pg.getByRole('button', { name: 'Sign in' }).click();
    await expect(pg).not.toHaveURL(/\/login/);
  };

  await signIn(page, email);
  await page.goto('/settings/data-export');
  await page.waitForLoadState('networkidle');
  await page.getByTestId('request-tenant-export').click();
  await expect(page.getByTestId('tenant-export')).toHaveCount(1);

  await expect.poll(async () => (await request.post('/api/internal/exports/run', { headers: { 'x-worker-secret': SECRET } })).status()).toBe(200);
  await page.reload();
  await expect(page.getByTestId('tenant-export').first()).toContainText('done', { timeout: 60000 });

  const link = await page.getByTestId('tenant-export-download').first().getAttribute('href');
  const file = await page.request.get(link!);
  expect(file.status()).toBe(200);
  const body = await file.body();
  expect(body.subarray(0, 2).toString()).toBe('PK');
  expect(body.toString('latin1')).toContain('manifest.json');
  expect(body.toString('latin1')).toContain('students.csv');

  const { data: audit } = await db.from('tenant_export_audit').select('checksum_sha256, row_counts').eq('tenant_id', tenant);
  expect(audit).toHaveLength(1);
  expect(audit![0]!.checksum_sha256).toMatch(/^[0-9a-f]{64}$/);
  expect((audit![0]!.row_counts as Record<string, number>)['students.csv']).toBe(3);

  // A Principal is refused, in the UI and at the link.
  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signIn(pp, principalEmail);
  await pp.goto('/settings/data-export');
  await expect(pp.getByTestId('export-not-permitted')).toBeVisible();
  const denied = await pp.request.get(link!, { maxRedirects: 0 });
  expect(denied.status()).toBe(403);
  await pctx.close();

  // 73 hours later the link is dead.
  const { data: reqRow } = await db.from('data_export_request').select('id').eq('tenant_id', tenant).single();
  await db.from('data_export_request').update({ completed_at: new Date(Date.now() - 73 * 3600e3).toISOString(), expires_at: new Date(Date.now() - 1 * 3600e3).toISOString() }).eq('id', reqRow!.id);
  const expired = await page.request.get(link!, { maxRedirects: 0 });
  expect(expired.status()).toBe(410);
  expect((await expired.json()).code).toBe('EXPORT_LINK_EXPIRED');
});
