import { test, expect } from '@playwright/test';
import { createClient } from '@supabase/supabase-js';
import { createHmac, randomUUID } from 'node:crypto';

// FR-K21/K22: the webhook route is the only authentication a gateway callback
// has. Asserts the HMAC gate, exactly-once posting and the duplicate reply.

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL ?? 'http://127.0.0.1:54321';
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;
const ANON_KEY = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;
const PW = 'e2e-test-password-123!';
const SECRET = process.env.PAY_SECRET_JAZZCASH!;

function must<T>(r: { data: T; error: { message: string } | null }, what: string): T {
  if (r.error) throw new Error(`${what}: ${r.error.message}`);
  return r.data;
}

const sign = (body: string) => createHmac('sha256', SECRET).update(body, 'utf8').digest('hex');

async function seedIntent() {
  const db = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const runId = randomUUID().slice(0, 8);
  const email = `owner-${runId}@pay-webhook-e2e.test`;
  const { data: tenantId, error } = await db.rpc('provision_tenant', { p_slug: `pay-e2e-${runId}`, p_legal_name: `Pay E2E ${runId}`, p_owner_email: email });
  if (error) throw error;
  const tenant = tenantId as string;
  const { data: owner } = await db.auth.admin.createUser({ email, password: PW, email_confirm: true });
  await db.from('app_user').insert({ user_id: owner.user!.id, tenant_id: tenant, app_role: 'owner', full_name: 'Owner' });
  const { data: campus } = await db.from('campus').select('id').eq('tenant_id', tenant).single();
  await db.from('user_campus').insert({ user_id: owner.user!.id, tenant_id: tenant, campus_id: campus!.id });
  const { data: session } = await db.from('academic_session').select('id').eq('tenant_id', tenant).single();
  const { data: level } = await db.from('class_level').select('id').eq('tenant_id', tenant).eq('code', '1').single();

  const owner$ = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  await owner$.auth.signInWithPassword({ email, password: PW });
  const { data: others } = await db.from('class_level').select('id').eq('tenant_id', tenant).neq('code', '1');
  for (const o of others ?? []) must(await owner$.rpc('set_class_level_active', { p_id: o.id, p_is_active: false }), 'deactivate level');
  const section = must(await owner$.rpc('create_section', { p_campus_id: campus!.id, p_session_id: session!.id, p_class_level_id: level!.id, p_name: 'A', p_capacity: 20 }), 'create_section');
  must(await owner$.rpc('seed_default_fee_heads', { p_tenant_id: tenant }), 'seed_fee_heads');
  const { data: head } = await db.from('fee_head').select('id').eq('tenant_id', tenant).eq('code', 'TUITION').single();
  const structure = must(await owner$.rpc('create_draft_structure', { p_campus_id: campus!.id, p_session_id: session!.id }), 'draft');
  must(await owner$.rpc('add_structure_line', { p_structure_id: structure as string, p_class_id: level!.id, p_fee_head_id: head!.id, p_amount_paisa: 850000, p_frequency: 'monthly' }), 'line');
  must(await owner$.rpc('publish_fee_structure', { p_structure_id: structure as string }), 'publish');
  const student = must(await owner$.rpc('create_student', { p_campus_id: campus!.id, p_name_en: 'Webhook Kid', p_dob: '2015-01-01', p_gender: 'male' }), 'student');
  const enrol = must(await owner$.rpc('enrol_student', { p_section_id: section as string, p_student_id: student as string }), 'enrol');
  const now = new Date();
  must(await owner$.rpc('generate_challans', { p_campus_id: campus!.id, p_session_id: session!.id, p_period: new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 15)).toISOString().slice(0, 10), p_dry_run: false }), 'challans');
  const { data: challan } = await db.from('fee_challan').select('id').eq('enrolment_id', enrol as string).single();

  const merchant = `MC-${runId}`;
  await db.from('payment_gateway_config').insert({ tenant_id: tenant, gateway: 'jazzcash', merchant_id: merchant, secret_ref: 'PAY_SECRET_JAZZCASH' });
  const ref = `JA-${runId}`;
  await db.from('payment_intent').insert({
    tenant_id: tenant, campus_id: campus!.id, enrolment_id: enrol as string, challan_id: challan!.id,
    gateway: 'jazzcash', gateway_ref: ref, amount_paisa: 850000, expires_at: new Date(Date.now() + 30 * 60_000).toISOString(),
  });
  return { db, merchant, ref, challanId: challan!.id as string, enrolId: enrol as string };
}

test.describe('FR-K22: payment webhook route', () => {
  test('rejects a bad signature, posts once, and answers replays with "duplicate"', async ({ request }) => {
    test.setTimeout(60000);
    const { db, merchant, ref, challanId, enrolId } = await seedIntent();
    const txn = `T-${randomUUID().slice(0, 8)}`;
    const body = JSON.stringify({ merchant_id: merchant, gateway_txn_id: txn, gateway_ref: ref, status: 'success', amount_paisa: 850000 });

    const forged = await request.post('/api/webhooks/payments/jazzcash', { data: body, headers: { 'content-type': 'application/json', 'x-signature': sign(body + 'x') } });
    expect(forged.status()).toBe(401);
    const unsigned = await request.post('/api/webhooks/payments/jazzcash', { data: body, headers: { 'content-type': 'application/json' } });
    expect(unsigned.status()).toBe(401);
    const unknown = await request.post('/api/webhooks/payments/stripe', { data: body, headers: { 'x-signature': sign(body) } });
    expect(unknown.status()).toBe(404);

    const ok = await request.post('/api/webhooks/payments/jazzcash', { data: body, headers: { 'content-type': 'application/json', 'x-signature': sign(body) } });
    expect(ok.status()).toBe(200);
    expect(await ok.text()).toBe('ok');

    for (let i = 0; i < 3; i++) {
      const dup = await request.post('/api/webhooks/payments/jazzcash', { data: body, headers: { 'content-type': 'application/json', 'x-signature': sign(body) } });
      expect(dup.status()).toBe(200);
      expect(await dup.text()).toBe('duplicate');
    }

    const { count } = await db.from('fee_payment').select('id', { count: 'exact', head: true }).eq('enrolment_id', enrolId).eq('reference_no', txn);
    expect(count).toBe(1);
    const { data: challan } = await db.from('fee_challan').select('status').eq('id', challanId).single();
    expect(challan?.status).toBe('paid');
  });
});
