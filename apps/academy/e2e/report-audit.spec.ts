import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-S11: the owner reads the trail, filters it, and exporting it is audited.

test('the owner filters the audit trail; exporting it writes a further audit row', async ({ page }) => {
  test.setTimeout(90000);
  const { db, owner$, email, tenant } = await seedFeesTenant(0, 'audit-e2e');
  const { data: me } = await owner$.auth.getUser();

  const { error: pii } = await owner$.rpc('record_report_run', { p_report_key: 'student_list', p_dataset_key: 'students', p_columns: ['gr_number', 'guardian_cnic'], p_filters: {}, p_row_count: 12, p_reason: 'Board registration forms for class 9', p_destination: 'xlsx' });
  expect(pii).toBeNull();
  const { error: noReason } = await owner$.rpc('record_report_run', { p_report_key: 'student_list', p_dataset_key: 'students', p_columns: ['guardian_cnic'], p_filters: {}, p_row_count: 1, p_reason: 'short', p_destination: 'xlsx' });
  expect(noReason?.message).toContain('REASON_REQUIRED_FOR_PII_EXPORT');
  await owner$.rpc('record_report_run', { p_report_key: 'fee_summary', p_dataset_key: 'fees', p_columns: ['net_paisa'], p_filters: {}, p_row_count: 5, p_destination: 'screen' });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).toHaveURL(/\/dashboard$/);

  await page.goto('/reports/audit');
  await expect(page.getByTestId('audit-row')).toHaveCount(2);
  await expect(page.getByTestId('audit-table')).toContainText('Board registration forms for class 9');

  await page.goto(`/reports/audit?user=${me.user!.id}`);
  await expect(page.getByTestId('audit-row')).toHaveCount(2);

  const res = await page.request.get(`/api/reports/audit/export?user=${me.user!.id}`);
  expect(res.status()).toBe(200);
  expect(res.headers()['content-type']).toContain('text/csv');
  const body = await res.text();
  expect(body).toContain('student_list');
  expect(body.split('\r\n').filter(Boolean).length).toBeGreaterThanOrEqual(3);

  const { count } = await db.from('report_audit').select('id', { count: 'exact', head: true }).eq('tenant_id', tenant).eq('report_key', 'report_audit');
  expect(count).toBe(1);
});
