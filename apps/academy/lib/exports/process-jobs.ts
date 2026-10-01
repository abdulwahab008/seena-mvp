import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import type { Database } from '@/lib/database.types';
import { buildWorkbook, metadataSheet, type Cell, type Column } from '@/lib/xlsx/writer';

const PAGE = 5000;
const MAX_ROWS = 500_000;
const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

const columnSchema = z.array(z.object({ key: z.string(), label: z.string(), type: z.enum(['text', 'int', 'money', 'date']) }));
const pageSchema = z.array(z.record(z.union([z.string(), z.number(), z.null()])));

type Db = SupabaseClient<Database>;

// Claims queued jobs and builds their workbooks. Runs in the long-running
// worker route — never in the request that asked for the export.
export async function processExportJobs(db: Db, maxJobs = 3): Promise<{ processed: number; failed: number }> {
  let processed = 0;
  let failed = 0;
  for (let i = 0; i < maxJobs; i++) {
    const { data: claimed, error } = await db.rpc('claim_export_job');
    const job = claimed?.[0];
    if (error || !job) break;
    try {
      const columns: Column[] = columnSchema.parse(job.columns);
      const rows: Record<string, Cell>[] = [];
      for (let offset = 0; offset < MAX_ROWS; offset += PAGE) {
        const { data, error: pageError } = await db.rpc('export_job_page', { p_job_id: job.job_id, p_offset: offset, p_limit: PAGE });
        if (pageError) throw new Error(pageError.message);
        const page = pageSchema.parse(data);
        rows.push(...page);
        if (page.length < PAGE) break;
      }

      const bytes = buildWorkbook([
        { name: job.display_name, columns, rows },
        metadataSheet({ report: job.display_name, filters: z.record(z.unknown()).parse(job.params ?? {}), requestedBy: job.requester_name, generatedAt: new Date() }),
      ]);
      const path = `${job.tenant_id}/${job.requested_by}/${job.job_id}.xlsx`;
      const { error: uploadError } = await db.storage.from('report_exports').upload(path, bytes, { contentType: XLSX_TYPE, upsert: true });
      if (uploadError) throw new Error(`upload: ${uploadError.message}`);

      await db.rpc('complete_export_job', { p_job_id: job.job_id, p_row_count: rows.length, p_storage_path: path });
      processed++;
    } catch (e) {
      await db.rpc('fail_export_job', { p_job_id: job.job_id, p_error: e instanceof Error ? e.message : 'unknown error' });
      failed++;
    }
  }
  return { processed, failed };
}

export async function purgeExpiredExports(db: Db): Promise<number> {
  const { data } = await db.rpc('export_jobs_to_purge', { p_limit: 200 });
  let purged = 0;
  for (const row of data ?? []) {
    const { error } = await db.storage.from('report_exports').remove([row.storage_path]);
    if (error) continue;
    await db.rpc('mark_export_purged', { p_job_id: row.job_id });
    purged++;
  }
  return purged;
}
