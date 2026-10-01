import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';

export const maxDuration = 300;

// FR-T16: nightly at 03:30 Asia/Karachi from the scheduler (pg_cron runs the same function where
// available). Runs the batched, resumable purge, then deletes the photo blobs named on the purge
// items through the storage API (bucket lifecycle rules cannot be set from SQL).
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const db = supabaseServiceRole();
  const { data: tenants } = await db.rpc('retention_purge_nightly');
  const { data: blobs } = await db.rpc('retention_blobs_to_delete', { p_limit: 500 });
  let deleted = 0;
  for (const b of blobs ?? []) {
    if (!b.storage_bucket) continue;
    const { error } = await db.storage.from(b.storage_bucket).remove([b.storage_path]);
    // a bucket that does not exist, or an object already gone, counts as deleted: there is nothing left to keep
    if (error && !/not found|does not exist/i.test(error.message)) continue;
    await db.rpc('mark_retention_blob_deleted', { p_item_id: b.item_id });
    deleted++;
  }
  return NextResponse.json({ tenants: tenants ?? 0, blobsDeleted: deleted });
}
