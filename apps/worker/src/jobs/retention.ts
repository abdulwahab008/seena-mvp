import { lt, eq } from 'drizzle-orm';
import { db, schema } from '../db.js';
import { env } from '../env.js';
import { deleteObject } from '../storage.js';

/**
 * Delete submissions (and their stored answer-sheet PDFs) older than the
 * configured retention window. No-op unless SUBMISSION_RETENTION_DAYS is set —
 * data retention should be an explicit choice, not a silent default.
 */
export async function purgeOldSubmissions(): Promise<void> {
  const days = env().SUBMISSION_RETENTION_DAYS;
  if (!days) {
    console.log('[retention] SUBMISSION_RETENTION_DAYS not set — skipping');
    return;
  }
  const cutoff = new Date(Date.now() - days * 86_400_000);
  const old = await db
    .select({ id: schema.submissions.id, storageKey: schema.submissions.storageKey })
    .from(schema.submissions)
    .where(lt(schema.submissions.createdAt, cutoff));

  for (const s of old) {
    try {
      await deleteObject(s.storageKey);
    } catch (e) {
      console.warn(`[retention] storage delete failed for ${s.id} (non-fatal)`, e);
    }
    await db.delete(schema.submissions).where(eq(schema.submissions.id, s.id));
  }
  console.log(`[retention] purged ${old.length} submissions older than ${days}d`);
}
