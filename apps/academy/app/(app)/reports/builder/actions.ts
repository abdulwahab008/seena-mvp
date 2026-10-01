'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import {
  exportSavedReportSchema,
  reportDefinitionSchema,
  saveReportSchema,
  type ExportSavedReportInput,
  type ReportDefinitionInput,
  type SaveReportInput,
} from '@/lib/validation';

export type PreviewResult = {
  error: string | null;
  columns?: { key: string; label: string; type: string }[];
  rows?: Record<string, string | number | boolean | null>[];
  totalRows?: number;
  capped?: boolean;
  notice?: string | null;
  elapsedMs?: number;
};

function mapError(message: string): string {
  if (message.includes('column_not_permitted')) return 'This report uses a column your role is not allowed to see.';
  if (message.includes('DATASET_NOT_AVAILABLE')) return 'You do not have access to this dataset.';
  if (message.includes('DEFINITION_INVALID')) return `The report definition is not valid${/DETAIL:\s*(.+)/.exec(message)?.[1] ? `: ${/DETAIL:\s*(.+)/.exec(message)![1]}` : '.'}`;
  if (message.includes('REPORT_NOT_FOUND')) return 'That report does not exist or is not shared with you.';
  if (message.includes('REASON_REQUIRED_FOR_PII_EXPORT')) return 'This report contains personal data. Give a reason of at least 20 characters.';
  if (message.includes('invalid input syntax')) return 'One of the filter values does not match its column type (for example text in a number column).';
  return 'Something went wrong. Please try again.';
}

// The UI works with strings; the server's definition format uses typed JSON values.
export function toServerDefinition(d: z.output<typeof reportDefinitionSchema>) {
  return {
    columns: d.columns,
    group_by: d.groupBy,
    filters: d.filters.map((f) => ({
      column: f.column,
      op: f.op,
      ...(f.op === 'is_null' || f.op === 'not_null' ? {} : { value: f.op === 'in' ? (f.value ?? '').split(',').map((v) => v.trim()).filter(Boolean) : (f.value ?? '') }),
    })),
  };
}

export async function previewReport(datasetKey: string, definition: ReportDefinitionInput, page = 1): Promise<PreviewResult> {
  const d = reportDefinitionSchema.safeParse(definition);
  if (!d.success) return { error: d.error.issues[0]?.message ?? 'Invalid report.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_preview_report', { p_dataset_key: datasetKey, p_definition: toServerDefinition(d.data), page, page_size: 100 });
  if (error) return { error: mapError(error.message) };
  const r = z
    .object({
      columns: z.array(z.object({ key: z.string(), label: z.string(), type: z.string() })),
      rows: z.array(z.record(z.union([z.string(), z.number(), z.boolean(), z.null()]))),
      total_rows: z.number(),
      capped: z.boolean(),
      notice: z.string().nullable().optional(),
      elapsed_ms: z.number().optional(),
    })
    .safeParse(data);
  if (!r.success) return { error: 'Unexpected response from the server.' };
  return { error: null, columns: r.data.columns, rows: r.data.rows, totalRows: r.data.total_rows, capped: r.data.capped, notice: r.data.notice, elapsedMs: r.data.elapsed_ms };
}

export async function saveReport(input: SaveReportInput): Promise<{ error: string | null; id?: string }> {
  const p = saveReportSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid report.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_report', {
    p_name: p.data.name,
    p_dataset_key: p.data.datasetKey,
    p_definition: toServerDefinition(p.data.definition),
    p_is_shared: p.data.isShared,
    p_id: p.data.id,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/reports/builder');
  return { error: null, id: data };
}

export async function deleteReport(id: string): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid report.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_saved_report', { p_id: id });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/reports/builder');
  return { error: null };
}

// The asynchronous export for a report too large for the preview. Audited like every export (FR-S11).
export async function exportReport(input: ExportSavedReportInput): Promise<{ error: string | null }> {
  const p = exportSavedReportSchema.safeParse(input);
  if (!p.success) return { error: 'Invalid request.' };
  const h = await headers();
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('request_saved_report_export', {
    p_saved_report_id: p.data.id,
    p_format: p.data.format,
    p_reason: p.data.reason || undefined,
    p_ip: clientIpFromHeaders(h) ?? undefined,
  });
  if (error) return { error: mapError(error.message) };
  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = h.get('host');
  const deduplicated = (data as { deduplicated?: boolean } | null)?.deduplicated;
  if (secret && host && !deduplicated) {
    const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
    void fetch(`${proto}://${host}/api/internal/exports/run`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
  }
  return { error: null };
}
