import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-G07: a parent applies for leave for a linked child only, in their own language, with attachments capped at 10 MB.

test('a parent applies for leave: own children only, date order, overlap, attachment cap', async ({ page }) => {
  test.setTimeout(120000);
  const { db, tenant, challans } = await seedFeesTenant(2, 'leave-e2e');
  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const email = `parent-${randomUUID().slice(0, 8)}@leave-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Leave Parent', phone_e164: '+923001238888', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);
  await page.goto('/portal/leave');

  await expect(page.locator('#leaveChild option')).toHaveCount(1);

  await page.getByLabel('From').fill('2026-09-10');
  await page.getByLabel('To', { exact: true }).fill('2026-09-08');
  await page.getByTestId('leave-submit').click();
  await expect(page.getByTestId('leave-error-to')).toHaveText('End date must be on or after start date');

  await page.getByTestId('language-toggle').click();
  await page.getByTestId('leave-submit').click();
  await expect(page.getByTestId('leave-error-to')).toHaveText('اختتامی تاریخ ابتدائی تاریخ کے برابر یا اس کے بعد ہونی چاہیے');
  await page.getByTestId('language-toggle').click();

  await page.getByLabel('To', { exact: true }).fill('2026-09-12');
  await page.getByLabel(/Remarks/).fill('بخار کی وجہ سے');
  await page.getByLabel(/Attachments/).setInputFiles([
    { name: 'doctor.pdf', mimeType: 'application/pdf', buffer: Buffer.alloc(6 * 1024 * 1024, 1) },
    { name: 'report.png', mimeType: 'image/png', buffer: Buffer.alloc(5 * 1024 * 1024, 2) },
  ]);
  await page.getByTestId('leave-submit').click();
  await expect(page.getByTestId('leave-file-errors')).toContainText('report.png');
  await expect(page.getByTestId('leave-row')).toHaveCount(1);
  await expect(page.getByTestId('leave-row')).toContainText('doctor.pdf');
  await expect(page.getByTestId('leave-row')).not.toContainText('report.png');
  await expect(page.getByTestId('leave-row')).toContainText('بخار کی وجہ سے');

  await page.getByLabel('From').fill('2026-09-11');
  await page.getByLabel('To', { exact: true }).fill('2026-09-14');
  await page.getByTestId('leave-submit').click();
  await expect(page.getByTestId('leave-error')).toHaveText('A leave request already covers 2026-09-11');
});
