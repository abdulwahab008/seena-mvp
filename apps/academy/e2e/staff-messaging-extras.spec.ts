import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

test('HR places a teacher under the head and the org chart nests them', async ({ page }) => {
  const { owner, mkUser } = await seedHrTenant('org-chart');
  const head = await mkUser('head', 'principal', { staff: {} });
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: {} });
  await signInAs(page, owner.email);

  await page.goto('/staff/org-chart');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Staff member').selectOption(teacher.staffId!);
  await page.getByLabel('Reports to').selectOption(head.staffId!);
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByText('Org chart updated.')).toBeVisible();
  const headNode = page.getByTestId('org-node').filter({ hasText: 'head user' }).first();
  await expect(headNode.getByTestId('org-node')).toContainText('teacher user');
});

test('HR adds a pay scale and it can be picked on a salary structure', async ({ page }) => {
  const { owner } = await seedHrTenant('pay-scale');
  await signInAs(page, owner.email);

  await page.goto('/payroll/pay-scales');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Code').fill('bps-14');
  await page.getByLabel('Name').fill('Basic Pay Scale 14');
  await page.getByLabel('Minimum basic (PKR)').fill('35000');
  await page.getByLabel('Maximum basic (PKR)').fill('65000');
  await page.getByLabel('Annual increment (PKR)').fill('1500');
  await page.getByRole('button', { name: 'Add pay scale' }).click();
  const row = page.getByTestId('pay-scale-row');
  await expect(row).toContainText('BPS-14');
  await expect(row.locator('td').nth(5)).toHaveText('20');

  await page.goto('/payroll/structures');
  await page.getByRole('button', { name: /Assign \/ Revise/ }).click();
  await expect(page.getByLabel('Pay Scale').locator('option', { hasText: 'BPS-14' })).toHaveCount(1);
});

test('the front desk queues a quick SMS into the outbox', async ({ page }) => {
  const { owner, db, tenantId } = await seedHrTenant('quick-sms');
  await signInAs(page, owner.email);

  await page.goto('/front-desk');
  await page.waitForLoadState('networkidle');
  const panel = page.getByTestId('quick-sms');
  await panel.getByLabel('Send to').selectOption('numbers');
  await panel.getByLabel('Mobile numbers').fill('0300 1234567, 0321-7654321, 12');
  await panel.getByLabel('Message').fill('School will remain closed tomorrow.');
  await panel.getByRole('button', { name: 'Queue SMS' }).click();
  await expect(page.getByText('Queued 2 SMS; 1 had no valid number.')).toBeVisible();
  const { data } = await db.from('message').select('recipient_phone, status').eq('tenant_id', tenantId).eq('channel', 'sms').order('recipient_phone');
  expect(data).toEqual([
    { recipient_phone: '+923001234567', status: 'queued' },
    { recipient_phone: '+923217654321', status: 'queued' },
  ]);
});

test('the email log lists failed emails with the reason', async ({ page }) => {
  const { owner, db, tenantId, campusId } = await seedHrTenant('email-log');
  const { data: failed } = await db
    .from('message')
    .insert({ tenant_id: tenantId, campus_id: campusId, channel: 'email', recipient_email: 'parent@example.test', subject: 'Fee reminder', body: 'x', status: 'failed' })
    .select('id')
    .single();
  await db.from('message_attempt').insert({ message_id: failed!.id, attempt_number: 1, channel: 'email', status: 'failed', error_message: 'Mailbox does not exist' });
  await db.from('message').insert({ tenant_id: tenantId, campus_id: campusId, channel: 'email', recipient_email: 'ok@example.test', subject: 'Welcome', body: 'x', status: 'delivered' });
  await signInAs(page, owner.email);

  await page.goto('/communication/emails');
  await expect(page.getByTestId('email-row')).toHaveCount(2);
  await page.getByLabel('Status').selectOption('failed');
  await page.getByRole('button', { name: 'Filter' }).click();
  await expect(page.getByTestId('email-row')).toHaveCount(1);
  await expect(page.getByTestId('email-row')).toContainText('Mailbox does not exist');
});

test('staff start a discussion and reply to it', async ({ page }) => {
  const { owner } = await seedHrTenant('discussions');
  await signInAs(page, owner.email);

  await page.goto('/communication/discussions');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Title').fill('Sports day duties');
  await page.getByLabel('Message').fill('Who can cover the relay track?');
  await page.getByRole('button', { name: 'Start thread' }).click();
  await expect(page.getByRole('heading', { name: 'Sports day duties' })).toBeVisible();
  await page.getByLabel('Your reply').fill('I can take it.');
  await page.getByRole('button', { name: 'Reply' }).click();
  await expect(page.getByTestId('discussion-reply')).toContainText('I can take it.');
  await page.goto('/communication/discussions');
  await expect(page.getByTestId('discussion-thread')).toContainText('1 reply');
});
