import { NextRequest, NextResponse } from 'next/server';
import { z } from 'zod';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { isGateway, verifySignature } from '@/lib/payments/gateways';

const MAX_BODY_BYTES = 64 * 1024;
const NIL_UUID = '00000000-0000-0000-0000-000000000000';

const payloadSchema = z.object({
  merchant_id: z.string().min(1).max(100),
  gateway_txn_id: z.string().min(1).max(100),
  gateway_ref: z.string().min(1).max(100),
  status: z.string().max(30),
  amount_paisa: z.number().int().positive().optional(),
});

// No Supabase JWT exists for a gateway: the HMAC below is the only
// authentication, and it runs before any database write other than the raw
// event capture inside ingest_payment_webhook().
export async function POST(req: NextRequest, { params }: { params: Promise<{ gateway: string }> }) {
  const { gateway } = await params;
  if (!isGateway(gateway)) return NextResponse.json({ error: 'unknown gateway' }, { status: 404 });

  const raw = await req.text();
  if (Buffer.byteLength(raw, 'utf8') > MAX_BODY_BYTES) return NextResponse.json({ error: 'payload too large' }, { status: 413 });

  const db = supabaseServiceRole();
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    json = null;
  }
  const parsed = payloadSchema.safeParse(json);

  // Find the merchant's secret by the merchant id the payload CLAIMS; the
  // claim is only ever used to pick which secret to verify against.
  let secret: string | undefined;
  let tenantId: string | null = null;
  if (parsed.success) {
    const { data: cfg } = await db
      .from('payment_gateway_config')
      .select('tenant_id, secret_ref, is_enabled')
      .eq('gateway', gateway)
      .eq('merchant_id', parsed.data.merchant_id)
      .maybeSingle();
    if (cfg?.is_enabled) {
      secret = process.env[cfg.secret_ref];
      tenantId = cfg.tenant_id;
    }
  }

  const valid = Boolean(secret) && parsed.success && verifySignature(secret as string, raw, req.headers.get('x-signature'));

  const { data, error } = await db.rpc('ingest_payment_webhook', {
    p_tenant_id: valid && tenantId ? tenantId : NIL_UUID,
    p_gateway: gateway,
    p_txn_id: valid && parsed.success ? parsed.data.gateway_txn_id : '',
    p_payload: valid && parsed.success ? parsed.data : {},
    p_raw: raw,
    p_signature_valid: valid,
  });
  if (error) return NextResponse.json({ error: 'processing failed' }, { status: 500 });

  const result = (data as { result?: string } | null)?.result;
  if (result === 'signature_invalid' || result === 'rate_limited') {
    return NextResponse.json({ error: 'invalid signature' }, { status: result === 'rate_limited' ? 429 : 401 });
  }
  return new NextResponse(result === 'duplicate' ? 'duplicate' : 'ok', { status: 200 });
}
