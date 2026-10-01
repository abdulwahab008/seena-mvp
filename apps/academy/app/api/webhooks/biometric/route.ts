import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifySignature } from '@/lib/biometric/signature';
import { MAX_PUNCHES_PER_CALL, parseBatch } from '@/lib/biometric/payload';

// FR-D08 (ingest-biometric-punch): called by the on-premise agent that sits
// beside the fingerprint device. No user session - the device proves itself by
// signing the raw body with HMAC-SHA256 keyed by sha256(its device key).
//
//   x-device-serial: ZK-TEST-0001
//   x-signature:     hex(hmac_sha256(sha256(device_key), rawBody))
//   body:            { "punches": [{ "code": "101", "time": "2026-08-03T08:00:00+05:00", "direction": "in" }] }
//
// The batch may be hours or days old, out of order, or a retry; the database
// is idempotent on (device, code, punch_time) and derives each punch's own day.
export const maxDuration = 60;

export async function POST(req: NextRequest) {
  const rawBody = await req.text();
  const serial = req.headers.get('x-device-serial')?.trim();
  if (!serial) return NextResponse.json({ error: 'Missing x-device-serial.' }, { status: 401 });

  const admin = supabaseServiceRole();
  const { data: device } = await admin.from('biometric_device').select('id, api_key_hash, is_active').eq('device_serial', serial).maybeSingle();
  // Same answer for an unknown serial and a bad signature: do not reveal which devices exist.
  if (!device || !device.is_active || !verifySignature(device.api_key_hash, rawBody, req.headers.get('x-signature'))) {
    return NextResponse.json({ error: 'Unauthorized.' }, { status: 401 });
  }

  const batch = parseBatch(rawBody);
  if (!batch.ok) return NextResponse.json({ error: batch.error, max: MAX_PUNCHES_PER_CALL }, { status: batch.status });

  const { data, error } = await admin.rpc('ingest_biometric_punches', { p_device_id: device.id, p_punches: batch.punches });
  if (error) {
    const status = error.message.includes('BATCH_TOO_LARGE') ? 413 : 500;
    return NextResponse.json({ error: status === 413 ? 'Batch too large.' : 'Could not ingest the batch.' }, { status });
  }
  return NextResponse.json({ ok: true, result: data });
}
