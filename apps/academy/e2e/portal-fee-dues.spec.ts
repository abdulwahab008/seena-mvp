import { test, expect } from '@playwright/test';
import { randomUUID } from 'node:crypto';
import { seedFeesTenant, SEED_PASSWORD } from './support/fees-seed';

// FR-N04: a parent sees exactly what they owe, separate late fee, the
// "under reconciliation" guard, a PDF challan without a gateway, and a 1LINK
// voucher reference with one.

test('parent dues: PDF without a gateway, pay options with one, reconciliation guard, late fee line', async ({ page }) => {
  test.setTimeout(120000);
  const { db, owner$, tenant, campusId, challans } = await seedFeesTenant(1, 'dues-e2e');
  const challan = challans[0]!;

  const { data: enrolment } = await db.from('enrolment').select('student_id, session_id').eq('id', challan.enrolment_id).single();
  const email = `parent-${randomUUID().slice(0, 8)}@dues-e2e.test`;
  const { data: user } = await db.auth.admin.createUser({ email, password: SEED_PASSWORD, email_confirm: true });
  const { data: guardian } = await db
    .from('guardian')
    .insert({ tenant_id: tenant, name_en: 'Dues Parent', phone_e164: '+923001230000', auth_user_id: user.user!.id })
    .select('id')
    .single();
  await db.from('student_guardian').insert({ tenant_id: tenant, student_id: enrolment!.student_id, guardian_id: guardian!.id, relationship: 'father', is_primary: true, receives_billing: true });

  await page.goto('/login');
  await page.waitForLoadState('networkidle');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(SEED_PASSWORD);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/portal/);

  // 1. No gateway: the PDF is offered, downloads fast, and is a real PDF.
  await page.goto('/portal/fees');
  await expect(page.getByTestId(`challan-pdf-${challan.challan_no}`)).toBeVisible();
  await expect(page.getByTestId(`pay-onelink-${challan.challan_no}`)).toHaveCount(0);
  const started = Date.now();
  const pdf = await page.request.get(`/api/challans/${challan.id}/pdf`);
  expect(pdf.status()).toBe(200);
  expect(pdf.headers()['content-type']).toBe('application/pdf');
  expect((await pdf.body()).subarray(0, 4).toString()).toBe('%PDF');
  expect(Date.now() - started).toBeLessThan(5000);

  // 2. A late fee rule and an overdue challan: the fee is its own line and the total adds up.
  await db.from('late_fee_rule').insert({ tenant_id: tenant, campus_id: campusId, session_id: enrolment!.session_id, grace_days: 0, basis: 'flat', amount_paisa: 10000, effective_from: '2000-01-01' });
  await db.from('fee_challan').update({ due_date: new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10) }).eq('id', challan.id);
  await page.goto('/portal/fees');
  await expect(page.getByTestId(`balance-${challan.challan_no}`)).toHaveText('PKR 8,500');
  await expect(page.getByTestId(`late-fee-${challan.challan_no}`)).toHaveText('PKR 100');
  await expect(page.getByTestId(`total-due-${challan.challan_no}`)).toHaveText('PKR 8,600');

  // 3. A gateway is configured: Pay buttons appear; 1LINK shows the voucher reference = challan number.
  await db.from('payment_gateway_config').insert({ tenant_id: tenant, gateway: 'onelink', merchant_id: 'MC-1L', secret_ref: 'PAY_SECRET_ONELINK' });
  await page.goto('/portal/fees');
  await page.getByTestId(`pay-onelink-${challan.challan_no}`).click();
  await expect(page.getByTestId(`voucher-${challan.challan_no}`)).toContainText(challan.challan_no);

  // 4. Paid at the bank yesterday, not yet reconciled: no second payment allowed.
  const { data: account } = await db.from('campus_bank_account').insert({ campus_id: campusId, bank_name: 'HBL', title: 'Dues', account_no: '42', iban: 'PK36HABB0000000000000042' }).select('id').single();
  const { data: imp } = await db.from('bank_statement_import').insert({ tenant_id: tenant, campus_id: campusId, bank_account_id: account!.id, file_sha256: 'a'.repeat(64) }).select('id').single();
  await db.from('bank_statement_line').insert({ tenant_id: tenant, campus_id: campusId, import_id: imp!.id, line_no: 2, txn_date: new Date().toISOString().slice(0, 10), challan_ref: challan.challan_no, amount_paisa: 850000, bank_ref: 'BK-42', raw_line: 'x' });
  await page.goto('/portal/fees');
  await expect(page.getByTestId(`under-reconciliation-${challan.challan_no}`)).toBeVisible();
  await expect(page.getByTestId(`pay-disabled-${challan.challan_no}`)).toBeDisabled();
  await expect(page.getByTestId(`pay-onelink-${challan.challan_no}`)).toHaveCount(0);

  // 5. Reconciliation posts the payment: the challan reads Paid and the guard is gone.
  await db.from('bank_statement_line').update({ status: 'matched' }).eq('import_id', imp!.id);
  const { error: payError } = await owner$.rpc('record_payment', { p_enrolment_id: challan.enrolment_id, p_amount_paisa: 850000, p_mode: 'bank_challan' });
  expect(payError).toBeNull();
  await page.goto('/portal/fees');
  await expect(page.getByTestId(`challan-status-${challan.challan_no}`)).toHaveText('Paid');
  await expect(page.getByTestId(`under-reconciliation-${challan.challan_no}`)).toHaveCount(0);
  await expect(page.getByTestId(`pay-onelink-${challan.challan_no}`)).toHaveCount(0);
});
