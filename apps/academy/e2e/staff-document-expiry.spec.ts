import { test, expect } from '@playwright/test';
import { seedHrTenant, signInAs } from './support/hr-seed';

// FR-D06: HR records a police verification, the expiry check arms exactly one reminder, an expired mandatory
// document makes the staff member non-compliant on the Principal's tile, and a renewal restores compliance.

const iso = (offsetDays: number) => new Date(Date.now() + offsetDays * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

test('expiry reminders are armed once and the compliance tile follows the documents', async ({ page, browser, baseURL }) => {
  test.setTimeout(120000);
  const { db, tenantId, mkUser, owner } = await seedHrTenant('docexp-e2e');
  const teacher = await mkUser('teacher', 'subject_teacher', { staff: { mobile: '+923001112233' } });
  const principal = await mkUser('principal', 'principal');

  await signInAs(page, owner.email);
  await page.goto('/staff/compliance');
  await page.getByLabel('Staff member').selectOption(teacher.userId);
  await page.getByLabel('Document').selectOption('police_verification');
  await page.getByLabel('Expires on').fill(iso(40));
  await page.getByTestId('save-document').click();
  await expect(page.getByTestId('expiring-row')).toHaveCount(1);

  await page.getByTestId('run-expiry-check').click();
  await expect(page.getByTestId('expiring-row')).toContainText('60-day reminder sent');
  await page.getByTestId('run-expiry-check').click();
  const { count } = await db.from('staff_document_reminder').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId);
  expect(count).toBe(1);
  const { count: queued } = await db.from('message').select('id', { count: 'exact', head: true }).eq('tenant_id', tenantId).eq('channel', 'sms');
  expect(queued).toBe(1);

  // An expired mandatory document is non-compliant and counted on the Principal's tile.
  const { data: doc } = await db.from('staff_document').select('id').eq('tenant_id', tenantId).single();
  await db.from('staff_document').update({ expires_on: iso(-2) }).eq('id', doc!.id);
  const pctx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const pp = await pctx.newPage();
  await signInAs(pp, principal.email);
  await pp.goto('/staff/compliance');
  await expect(pp.getByTestId('tile-non-compliant')).toHaveText('1');
  await expect(pp.getByTestId('add-document-form')).toHaveCount(0);

  // Renewal flips it back.
  await page.goto('/staff/compliance');
  await page.getByLabel('New expiry date').fill(iso(300));
  await page.getByTestId('renew-document').click();
  await pp.reload();
  await expect(pp.getByTestId('tile-non-compliant')).toHaveText('0');
  await pctx.close();
});
