import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';

const claimedSchema = z.array(z.object({ id: z.string().uuid(), bucket: z.string(), path: z.string() }));

// Drains storage_delete_queue: removes each object, then marks the row done (or
// records the error for a retry, up to 5 attempts). A missing object counts as
// removed, so a repeat run is harmless.
export async function processStorageDeletes(db: SupabaseClient): Promise<{ removed: number; failed: number }> {
  const { data, error } = await db.rpc('claim_storage_deletes', { p_limit: 100 });
  if (error) throw new Error(error.message);
  const rows = claimedSchema.parse(data ?? []);
  let removed = 0;
  let failed = 0;
  for (const row of rows) {
    const { error: removeError } = await db.storage.from(row.bucket).remove([row.path]);
    const missing = removeError?.message.toLowerCase().includes('not found');
    if (removeError && !missing) {
      failed += 1;
      await db.rpc('complete_storage_delete', { p_id: row.id, p_error: removeError.message });
    } else {
      removed += 1;
      await db.rpc('complete_storage_delete', { p_id: row.id });
    }
  }
  return { removed, failed };
}
