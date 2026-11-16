import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processStorageDeletes } from '@/lib/storage/purge';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';

export const maxDuration = 120;

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
  return NextResponse.json(await processStorageDeletes(supabaseServiceRole()));
}
