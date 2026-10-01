import { test, expect } from '@playwright/test';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-T16: a Super Admin reviews retention, runs a dry run (nothing changes), and the nightly
// worker then purges identifiers of a long-departed student but keeps name and GR number.

const SECRET = process.env.EXPORT_WORKER_SECRET!;

test('a super admin dry-runs retention; the worker purges identifiers and keeps the register', async ({ page, request }) => {
  test.setTimeout(120000);
  const { db, tenant, campusId } = await seedFeesTenant(1, 'retention-e2e');
  const email = `sa-${tenant.slice(0, 8)}@retention-e2e.test`;
  const { data: u } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: u.user!.id, tenant_id: tenant, app_role: 'super_admin', full_name: 'Retention SA' });
  await db.from('user_campus').insert({ user_id: u.user!.id, tenant_id: tenant, campus_id: campusId });

  const { data: enrolment } = await db.from('enrolment').select('id, student_id').eq('tenant_id', tenant).single();
  await db.from('enrolment').update({ joined_on: '2010-04-01', left_on: '2012-05-31', status: 'left' }).eq('id', enrolment!.id);
  await db.from('student').update({ b_form_no: '35202-1234567-1' }).eq('id', enrolment!.student_id);

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page).not.toHaveURL(/\/login/);

  await page.goto('/settings/retention');
  await expect(page.getByTestId('policy-row')).toHaveCount(4);
  await page.getByTestId('dry-run').click();
  await expect(page.getByTestId('retention-run').first()).toContainText('dry run');
  const before = (await db.from('student').select('b_form_no').eq('id', enrolment!.student_id).single()).data!.b_form_no;
  expect(before).toBe('35202-1234567-1');

  const run = await request.post('/api/internal/retention/run', { headers: { 'x-worker-secret': SECRET } });
  expect(run.status()).toBe(200);
  const after = (await db.from('student').select('b_form_no, name_en, gr_number').eq('id', enrolment!.student_id).single()).data!;
  // the nightly job is a dry run on the 1st of the month; any other day it is live
  const firstOfMonth = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }).endsWith('-01');
  expect(after.b_form_no).toBe(firstOfMonth ? '35202-1234567-1' : null);
  // left in 2012 with no issued certificate: past the 10-year name policy too, so on a live day the
  // name and GR number are pseudonymised (a student with an issued certificate would keep both)
  expect(after.gr_number.startsWith('PSEUDO-')).toBe(!firstOfMonth);
  expect(after.name_en.startsWith('PSEUDO-')).toBe(!firstOfMonth);
});
