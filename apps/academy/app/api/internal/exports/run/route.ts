import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processExportJobs } from '@/lib/exports/process-jobs';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

export const maxDuration = 300;

// Called by the long-running worker / scheduler (and kicked once by the request
// action for responsiveness). Reachable with the worker secret only.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const result = await processExportJobs(supabaseServiceRole());
  return NextResponse.json(result);
}
