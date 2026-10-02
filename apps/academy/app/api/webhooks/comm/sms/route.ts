import { NextRequest, NextResponse } from 'next/server';
import { verifyWebhookSignature, createAdminSupabaseClient } from '@/lib/comm-webhook-verifier';

export async function POST(req: NextRequest) {
  const rawBody = await req.text();
  const signature = req.headers.get('x-comm-signature') || req.headers.get('x-signature');

  // AC 2: Reject invalid or missing HMAC signature with 401
  if (!verifyWebhookSignature(rawBody, signature)) {
    return NextResponse.json(
      { error: 'Unauthorized: Invalid or missing HMAC signature' },
      { status: 401 }
    );
  }

  try {
    const payload = JSON.parse(rawBody);
    const provider = req.nextUrl.searchParams.get('provider') || payload.provider || 'sms_aggregator';
    const tenantId = req.nextUrl.searchParams.get('tenant_id') || payload.tenant_id || null;

    const supabase = createAdminSupabaseClient();
    const { data, error } = await supabase.rpc('apply_receipt', {
      p_provider: provider,
      p_payload: payload,
      p_tenant_id: tenantId,
    });

    if (error) {
      return NextResponse.json({ error: error.message }, { status: 400 });
    }

    return NextResponse.json({ ok: true, result: data });
  } catch (err: any) {
    return NextResponse.json({ error: err.message || 'Malformed payload' }, { status: 400 });
  }
}
