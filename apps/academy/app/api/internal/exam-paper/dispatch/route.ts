import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { dispatchDueJobs } from '@/lib/exams/paper-worker';

export const maxDuration = 300;

// Called by the scheduler: submits queued jobs whose backoff has passed and fails
// jobs whose worker never reported back. Reachable with the worker secret only.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.json(await dispatchDueJobs(supabaseServiceRole(), undefined, 20));
}
