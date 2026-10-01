import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { processStorageDeletes } from '@/lib/storage/purge';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

export const maxDuration = 120;

export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return NextResponse.json(await processStorageDeletes(supabaseServiceRole()));
}
