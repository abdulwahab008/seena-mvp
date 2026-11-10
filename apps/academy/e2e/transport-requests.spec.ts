import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';
import { signInAs } from './support/hr-seed';

test('a parent asks for the school bus from the portal and the transport office approves', async ({ page, browser }) => {
  test.setTimeout(120000);
  const { db, tenant, challans, email: ownerEmail } = await seedFeesTenant(1, 'bus-request-e2e');
  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();
  const email = `parent-${randomUUID().slice(0, 8)}@bus-request-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Bus Parent', phone_e164: '+923001237777', auth_user_id: user.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);
  await page.goto('/portal/transport');
  await page.waitForLoadState('networkidle');
  const form = page.getByTestId('transport-request-form');
  await form.getByRole('combobox', { name: 'Request' }).selectOption('start');
  await form.getByLabel(/Details/).fill('From Dhok Amb, from Monday');
  await form.getByRole('button', { name: 'Send request' }).click();
  await expect(page.getByText('Request sent.')).toBeVisible();
  await expect(page.getByTestId('my-transport-requests')).toContainText('Waiting for the school');

  const office = await browser.newPage();
  await signInAs(office, ownerEmail);
  await office.goto('/transport/requests');
  const row = office.getByTestId('transport-request-row');
  await expect(row).toContainText('Start bus');
  await expect(row).toContainText('From Dhok Amb, from Monday');
  await row.getByLabel('Decision note').fill('Route 2 from Monday');
  await row.getByRole('button', { name: 'Approve' }).click();
  await expect(office.getByText('Request approved.')).toBeVisible();
  const { data } = await db.from('transport_request').select('status, decision_note').eq('tenant_id', tenant);
  expect(data).toEqual([{ status: 'approved', decision_note: 'Route 2 from Monday' }]);
  await office.close();
});
