import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';
import { dispatchDueJobs } from '@/lib/exams/paper-worker';

export const maxDuration = 300;

// Called by the scheduler: submits queued jobs whose backoff has passed and fails
// jobs whose worker never reported back. Reachable with the worker secret only.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.json(await dispatchDueJobs(supabaseServiceRole(), undefined, 3));
}

// Vercel Cron (see vercel.json) sends a GET with the cron secret. Picks up jobs
// whose after-response dispatch was lost, and retries due ones.
export async function GET(req: NextRequest) {
  if (!verifyCronSecret(req.headers.get('authorization'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.json(await dispatchDueJobs(supabaseServiceRole(), undefined, 3));
}
