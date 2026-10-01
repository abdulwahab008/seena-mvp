import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processDigestDeliveries } from '@/lib/digests/process';
import { transportFor } from '@/lib/digests/transport';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

export const maxDuration = 120;

// FR-S05/S06: the digest worker. Called every few minutes by the scheduler (and by
// pg_cron's sibling job where pg_net exists). Authenticated by the worker secret only.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const result = await processDigestDeliveries(supabaseServiceRole(), transportFor());
  return NextResponse.json(result);
}
