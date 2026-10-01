import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { purgeExpiredExports } from '@/lib/exports/process-jobs';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

// Daily at 02:00 Asia/Karachi from the scheduler: deletes export files older
// than 30 days through the storage API and marks the jobs expired.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.json({ purged: await purgeExpiredExports(supabaseServiceRole()) });
}
