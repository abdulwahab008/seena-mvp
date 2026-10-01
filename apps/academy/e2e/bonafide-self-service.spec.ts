import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-T06: a guardian requests a bonafide certificate for the passport office, an officer approves, the PDF is issued and
// a WhatsApp message with a working 7-day link is queued. Also: the 3-a-day limit and the "Other" justification rule.

test('bonafide request, approval, WhatsApp link and the daily limit', async ({ page, browser, baseURL }) => {
  test.setTimeout(240000);
  const { db, owner$, tenant, campusId, challans } = await seedFeesTenant(2, 'bonafide-e2e');
  const { data: enrolment } = await db.from('enrolment').select('student_id').eq('id', challans[0]!.enrolment_id).single();

  const parentEmail = `parent-${randomUUID().slice(0, 8)}@bonafide-e2e.test`;
  const { data: parentUser } = await db.auth.admin.createUser({ email: parentEmail, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db.from('guardian').insert({ tenant_id: tenant, name_en: 'Bonafide Parent', phone_e164: '+923001230000', auth_user_id: parentUser.user!.id }).select('id').single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  const officerEmail = `officer-${randomUUID().slice(0, 8)}@bonafide-e2e.test`;
  const { data: officer } = await db.auth.admin.createUser({ email: officerEmail, password: SEED_PASSWORD, email_confirm: true });
  await db.from('app_user').insert({ user_id: officer.user!.id, tenant_id: tenant, app_role: 'admissions_officer', full_name: 'Farhat Jabeen' });
  await db.from('user_campus').insert({ user_id: officer.user!.id, tenant_id: tenant, campus_id: campusId });

  const { data: templateId, error: templateError } = await owner$.rpc('create_certificate_template', {
    p_certificate_type: 'bonafide',
    p_title: 'Bonafide Certificate',
    p_body_html: '<p>Certified that {{student.name_en}} (GR {{student.gr_number}}) is a bonafide student of class {{enrolment.class_name}}. Purpose: {{bonafide.purpose}}. Serial {{issue.serial_no}}, issued {{issue.date}}.</p>',
    p_language: 'en',
    p_page_size: 'A4',
    p_campus_id: campusId,
  });
  expect(templateError).toBeNull();
  const { error: activateError } = await owner$.rpc('activate_certificate_template', { p_template_id: templateId as string });
  expect(activateError).toBeNull();

  const signIn = async (p: import('@playwright/test').Page, email: string, landing: RegExp) => {
    await p.goto('/login');
    await p.waitForLoadState('networkidle');
    await p.getByLabel('Email').fill(email);
    await p.getByLabel('Password').fill(SEED_PASSWORD);
    await p.getByRole('button', { name: 'Sign in' }).click();
    await p.waitForURL(landing);
  };

  // the guardian asks, with the purposes in plain wording
  await signIn(page, parentEmail, /\/portal/);
  await page.goto('/portal/certificates');
  await expect(page.getByLabel('Child').locator('option')).toHaveCount(1);
  await page.getByLabel('What is it for?').selectOption('embassy/visa');
  await page.getByTestId('cert-request-submit').click();
  await expect(page.getByTestId('cert-request-row')).toHaveCount(1);
  await expect(page.getByTestId('cert-request-row')).toContainText('Waiting for the school');

  // "Other" needs a real explanation
  await page.getByLabel('What is it for?').selectOption('other');
  await page.getByLabel(/Please explain/).fill('too short');
  await page.getByTestId('cert-request-submit').click();
  await expect(page.getByTestId('cert-request-message')).toContainText('at least 15 characters');

  // the officer approves
  const officerCtx = await browser.newContext({ baseURL: baseURL ?? undefined });
  const officerPage = await officerCtx.newPage();
  await signIn(officerPage, officerEmail, /\/dashboard/);
  await officerPage.goto('/certificates/requests');
  await expect(officerPage.getByTestId('cert-queue-row')).toHaveCount(1);
  await officerPage.getByTestId('cert-approve').click();
  await expect(officerPage.getByTestId('cert-queue-empty')).toBeVisible({ timeout: 90000 });
  await officerCtx.close();

  const { data: request } = await db.from('certificate_request').select('status, certificate_issue_id').eq('tenant_id', tenant).single();
  expect(request!.status).toBe('issued');
  const { data: message } = await db.from('message').select('channel, recipient_phone, body').eq('tenant_id', tenant).single();
  expect(message!.channel).toBe('whatsapp');
  expect(message!.recipient_phone).toBe('+923001230000');
  const link = /https?:\/\/\S+\/api\/certificates\/share\/\S+/.exec(message!.body)![0];

  // the link opens the PDF without a login
  const shared = await page.request.get(link.replace(/^https?:\/\/[^/]+/, baseURL ?? 'http://localhost:3000'), { headers: { cookie: '' } });
  expect(shared.status()).toBe(200);
  expect(shared.headers()['content-type']).toContain('application/pdf');

  // the parent sees it ready, and the 4th request in a day is refused
  await page.goto('/portal/certificates');
  await expect(page.getByTestId('cert-download').first()).toBeVisible();
  await page.getByLabel('What is it for?').selectOption('passport');
  await page.getByTestId('cert-request-submit').click();
  await expect(page.getByTestId('cert-request-row')).toHaveCount(2);
  await page.getByLabel('What is it for?').selectOption('bank');
  await page.getByTestId('cert-request-submit').click();
  await expect(page.getByTestId('cert-request-row')).toHaveCount(3);
  await page.getByLabel('What is it for?').selectOption('scholarship');
  await page.getByTestId('cert-request-submit').click();
  await expect(page.getByTestId('cert-request-message')).toContainText('at most 3 requests a day');
});
