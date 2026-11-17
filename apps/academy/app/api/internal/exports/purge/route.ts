import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { purgeExpiredExports } from '@/lib/exports/process-jobs';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';
import { purgeExpiredTenantExports } from '@/lib/tenant-export/process';

// Daily at 02:00 Asia/Karachi from the scheduler: deletes export files older
// than 30 days through the storage API and marks the jobs expired.
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
  // FR-A19: whole-school archives expire after 72 hours and are deleted here too.
  return NextResponse.json({ purged: await purgeExpiredExports(db), tenantArchivesPurged: await purgeExpiredTenantExports(db) });
}
