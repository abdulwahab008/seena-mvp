import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processDigestDeliveries } from '@/lib/digests/process';
import { transportFor } from '@/lib/digests/transport';
import { WhatsAppCloudTransport } from '@/lib/digests/whatsapp';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';

export const maxDuration = 120;

// FR-S05/S06: the digest worker. Called every minute or so by the scheduler.
// Authenticated by the worker secret only. The WhatsApp token is read from the
// database vault (service role), never from a client-visible variable; without
// it WhatsApp digests use the dev transport instead of pretending to send.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

// Vercel Cron (see vercel.json) sends a GET with the cron secret.
export async function GET(req: NextRequest) {
  if (!verifyCronSecret(req.headers.get('authorization'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

async function run() {
  const db = supabaseServiceRole();
  const [{ data: token }, { data: phoneId }] = await Promise.all([
    db.rpc('digest_provider_secret', { p_name: 'whatsapp_waba_token' }),
    db.rpc('digest_provider_secret', { p_name: 'whatsapp_phone_number_id' }),
  ]);
  const whatsapp = token && phoneId ? new WhatsAppCloudTransport({ accessToken: token, phoneNumberId: phoneId }) : undefined;
  const result = await processDigestDeliveries(db, transportFor(process.env, whatsapp));
  return NextResponse.json(result);
}
