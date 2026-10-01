import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import type { Database } from '@/lib/database.types';
import { buildArchive, buildManifest, csvChunk, rowCountsByFile, UTF8_BOM, type ManifestFile } from './archive';

type Db = SupabaseClient<Database>;

const PAGE = 5000;
const tablesSchema = z.array(z.object({ table_key: z.string(), file_name: z.string(), columns: z.array(z.string()) }));
const pageSchema = z.array(z.record(z.unknown()));

// Claims queued tenant exports and builds their archives in the long-running worker route,
// one table page at a time, so no single request ever holds the whole school in memory
// except as the CSV text being assembled.
export async function processTenantExports(db: Db, maxJobs = 1): Promise<{ processed: number; failed: number }> {
  let processed = 0;
  let failed = 0;
  for (let i = 0; i < maxJobs; i++) {
    const { data: claimed, error } = await db.rpc('claim_tenant_export');
    const job = claimed?.[0];
    if (error || !job) break;
    try {
      const { data: tableData, error: tablesError } = await db.rpc('tenant_export_tables');
      if (tablesError) throw new Error(tablesError.message);
      const tables = tablesSchema.parse(tableData);

      const csvByFile = new Map<string, string>();
      const files: ManifestFile[] = [];
      for (const t of tables) {
        let text = UTF8_BOM;
        let rows = 0;
        for (let offset = 0; ; offset += PAGE) {
          const { data, error: pageError } = await db.rpc('tenant_export_page', { p_request_id: job.request_id, p_table_key: t.table_key, p_offset: offset, p_limit: PAGE });
          if (pageError) throw new Error(`${t.table_key}: ${pageError.message}`);
          const page = pageSchema.parse(data);
          text += csvChunk(t.columns, page, offset === 0);
          rows += page.length;
          if (page.length < PAGE) break;
        }
        csvByFile.set(t.file_name, text);
        files.push({ file: t.file_name, table: t.table_key, rows, bytes: new TextEncoder().encode(text).length });
      }

      const manifest = buildManifest({ requestId: job.request_id, tenantId: job.tenant_id, requestedBy: job.requested_by, generatedAt: new Date(), files });
      const archive = buildArchive(manifest, csvByFile);
      const path = `${job.tenant_id}/${job.request_id}.zip`;
      const { error: uploadError } = await db.storage.from('tenant-exports').upload(path, archive.bytes, { contentType: 'application/zip', upsert: true });
      if (uploadError) throw new Error(`upload: ${uploadError.message}`);

      await db.rpc('complete_tenant_export', {
        p_request_id: job.request_id,
        p_storage_path: path,
        p_bytes: archive.bytes.length,
        p_checksum: archive.sha256,
        p_row_counts: rowCountsByFile(manifest),
      });
      processed++;
    } catch (e) {
      await db.rpc('fail_tenant_export', { p_request_id: job.request_id, p_error: e instanceof Error ? e.message : 'unknown error' });
      failed++;
    }
  }
  return { processed, failed };
}

// Daily: archives past their 72 hours are marked expired by the database job; here the blobs go.
export async function purgeExpiredTenantExports(db: Db): Promise<number> {
  await db.rpc('expire_tenant_exports');
  const { data } = await db.rpc('tenant_exports_to_purge', { p_limit: 200 });
  let purged = 0;
  for (const row of data ?? []) {
    const { error } = await db.storage.from('tenant-exports').remove([row.storage_path]);
    if (error) continue;
    await db.rpc('mark_tenant_export_purged', { p_request_id: row.request_id });
    purged++;
  }
  return purged;
}
