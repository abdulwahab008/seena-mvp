import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from '@/lib/database.types';
import { assertProvenance, getPaperGenerator, paperPayloadSchema, type PaperGenerator } from './generator';

type Db = SupabaseClient<Database>;

// Claims submitted paper requests and has the generator answer them. Runs in
// the internal worker route, never in the request that asked for the paper.
export async function processPaperRequests(db: Db, generator: PaperGenerator = getPaperGenerator(), max = 3): Promise<{ generated: number; failed: number }> {
  let generated = 0;
  let failed = 0;
  for (let i = 0; i < max; i++) {
    const { data: claimed, error } = await db.rpc('claim_exam_paper_request');
    const job = claimed?.[0];
    if (error || !job) break;
    try {
      const payload = paperPayloadSchema.parse(job.payload);
      const questions = await generator.generate(payload);
      assertProvenance(payload, questions);
      const { error: recordError } = await db.rpc('record_generated_paper', { p_request_id: job.request_id, p_questions: questions });
      if (recordError) throw new Error(recordError.message);
      generated++;
    } catch (e) {
      await db.rpc('fail_exam_paper_request', { p_request_id: job.request_id, p_error: e instanceof Error ? e.message : 'unknown error' });
      failed++;
    }
  }
  return { generated, failed };
}
