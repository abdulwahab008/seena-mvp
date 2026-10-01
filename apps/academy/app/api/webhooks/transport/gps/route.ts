import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { GpsPayloadError, adapterFor } from '@/lib/transport/gps-adapter';
import { verifyHmacSignature } from '@/lib/transport/gps-auth';
import { loose } from '@/lib/transport/rpc';

// FR-P06 ingest hook. Two ways in, both fail closed:
//   * x-device-key: "<credential id>.<secret>" issued from the Live tracking page
//     (only a hash is stored); it names the school.
//   * x-signature: HMAC-SHA256 of the raw body with TRANSPORT_GPS_WEBHOOK_SECRET,
//     for a vendor cloud forwarding batches, plus ?tenant_id=.
// ?vendor= selects the payload adapter (default: the documented generic format).
// When the school's transport_gps flag is off the answer is 404 and nothing is
// written. Batches are capped at 100 pings.
export const dynamic = 'force-dynamic';

const json = (body: unknown, status: number) => NextResponse.json(body, { status });

export async function POST(req: NextRequest) {
  const raw = await req.text();
  const db = loose(supabaseServiceRole());

  let tenantId: string | null = null;
  const deviceKey = req.headers.get('x-device-key');
  if (deviceKey) {
    const { data } = await db.rpc('verify_gps_credential', { p_key: deviceKey });
    tenantId = (data as string | null) ?? null;
  } else if (verifyHmacSignature(process.env.TRANSPORT_GPS_WEBHOOK_SECRET, raw, req.headers.get('x-signature'))) {
    const claimed = req.nextUrl.searchParams.get('tenant_id');
    tenantId = claimed && /^[0-9a-f-]{36}$/i.test(claimed) ? claimed : null;
  }
  if (!tenantId) return json({ error: 'unauthorized' }, 401);

  const adapter = adapterFor(req.nextUrl.searchParams.get('vendor'));
  if (!adapter) return json({ error: 'unknown vendor' }, 400);

  let pings;
  try {
    pings = adapter.parse(JSON.parse(raw));
  } catch (e) {
    return json({ error: e instanceof GpsPayloadError ? e.message : 'malformed payload' }, 400);
  }
  if (pings.length === 0) return json({ accepted: 0, duplicates: 0, rejected: 0 }, 200);
  if (pings.length > 100) return json({ error: 'at most 100 pings per request' }, 413);

  const { data, error } = await db.rpc('ingest_vehicle_pings', { p_tenant_id: tenantId, p_pings: pings });
  if (error) {
    if (error.message.includes('FEATURE_OFF')) return json({ error: 'not found' }, 404);
    if (error.message.includes('BATCH_TOO_LARGE')) return json({ error: 'at most 100 pings per request' }, 413);
    return json({ error: 'ingest failed' }, 500);
  }
  return json(data, 200);
}
