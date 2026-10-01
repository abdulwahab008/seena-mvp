import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processPaperRequests } from '@/lib/exam-papers/process-requests';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

export const maxDuration = 300;

// Called by the worker / scheduler (and nudged once by the request action).
// Reachable with the worker secret only.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const result = await processPaperRequests(supabaseServiceRole());
  return NextResponse.json(result);
}
