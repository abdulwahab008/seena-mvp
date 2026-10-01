import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import type { Database } from '@/lib/database.types';
import { buildWorkbook, metadataSheet, type Cell, type Column } from '@/lib/xlsx/writer';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { pdfPageCount, renderPdf } from '@/lib/pdf/render';
import { buildReportPdf } from '@/lib/reports/pdf-html';
import { hasUrdu } from '@/lib/reports/pdf-layout';

const PAGE = 5000;
const MAX_ROWS = 500_000;
const XLSX_TYPE = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
const PNG_JPEG: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };

const brandingSchema = z.object({
  header_mode: z.enum(['letterhead', 'logo', 'none']),
  tenant_name: z.string(),
  tenant_name_ur: z.string().nullable().optional(),
  campus_name: z.string().nullable().optional(),
  campus_name_ur: z.string().nullable().optional(),
  address_en: z.string().nullable().optional(),
  address_ur: z.string().nullable().optional(),
  letterhead_path: z.string().nullable().optional(),
  logo_path: z.string().nullable().optional(),
});

async function imageDataUri(db: Db, storagePath: string | null | undefined): Promise<string | null> {
  if (!storagePath) return null;
  const { data } = await db.storage.from('branding').download(storagePath);
  if (!data) return null;
  const mime = PNG_JPEG[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

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

      let bytes: Uint8Array;
      let path: string;
      let contentType: string;
      let pageCount: number | undefined;
      let orientation: string | undefined;
      if (job.format === 'pdf') {
        // FR-S09: a branded, printable PDF through the house renderer. A job that cannot be
        // rendered faithfully (Urdu with no Nastaliq glyphs, columns too wide to fit) FAILS —
        // it never produces a file with tofu boxes or clipped text.
        const branding = brandingSchema.parse(await db.rpc('report_job_branding', { p_job_id: job.job_id, p_campus_id: job.campus_id as string }).then((r) => {
          if (r.error) throw new Error(r.error.message);
          return r.data;
        }));
        const font = resolveNastaliqFont();
        const built = buildReportPdf({
          title: job.display_name, columns, rows, branding,
          images: { letterheadDataUri: await imageDataUri(db, branding.letterhead_path), logoDataUri: await imageDataUri(db, branding.logo_path) },
          filters: z.record(z.unknown()).parse(job.params ?? {}), requestedBy: job.requester_name, generatedAt: new Date(), font,
        });
        if (!built.layout.fits) throw new Error('REPORT_TOO_WIDE: the selected columns cannot be printed legibly; choose fewer columns');
        if (built.strings.some(hasUrdu)) {
          if (!font) throw new Error('NASTALIQ_FONT_UNAVAILABLE: the worker has no Noto Nastaliq Urdu font installed');
          const coverage = checkGlyphCoverage(built.strings, parseCmapRanges(font.bytes));
          if (coverage.missing.length > 0) throw new Error(`NASTALIQ_GLYPHS_MISSING: ${coverage.missing.join(' ')}`);
        }
        bytes = new Uint8Array(await renderPdf(built.document));
        pageCount = pdfPageCount(bytes);
        orientation = built.orientation;
        path = `${job.tenant_id}/${job.requested_by}/${job.job_id}.pdf`;
        contentType = 'application/pdf';
      } else {
        bytes = buildWorkbook([
          { name: job.display_name, columns, rows },
          metadataSheet({ report: job.display_name, filters: z.record(z.unknown()).parse(job.params ?? {}), requestedBy: job.requester_name, generatedAt: new Date() }),
        ]);
        path = `${job.tenant_id}/${job.requested_by}/${job.job_id}.xlsx`;
        contentType = XLSX_TYPE;
      }
      const { error: uploadError } = await db.storage.from('report_exports').upload(path, bytes, { contentType, upsert: true });
      if (uploadError) throw new Error(`upload: ${uploadError.message}`);

      await db.rpc('complete_export_job', { p_job_id: job.job_id, p_row_count: rows.length, p_storage_path: path, p_page_count: pageCount, p_orientation: orientation });
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
