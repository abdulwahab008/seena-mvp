'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import { exportRequestSchema, type ExportRequestInput } from '@/lib/validation';

const responseSchema = z.object({ job_id: z.string().uuid(), deduplicated: z.boolean() });

export type RequestExportResult = { error: string } | { error: null; jobId: string; deduplicated: boolean };

function mapError(message: string): string {
  if (message.includes('REASON_REQUIRED_FOR_PII_EXPORT')) return 'This export contains personal data. Give a reason of at least 20 characters.';
  if (message.includes('DATASET_NOT_AVAILABLE')) return 'You do not have access to this export.';
  return 'Could not queue the export. Please try again.';
}

export async function requestExport(input: ExportRequestInput): Promise<RequestExportResult> {
  const parsed = exportRequestSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid request.' };

  const params: Record<string, string | boolean> = {};
  if (parsed.data.datasetKey === 'fee_collection') {
    if (parsed.data.from) params.from = parsed.data.from;
    if (parsed.data.to) params.to = parsed.data.to;
  }
  if (parsed.data.datasetKey === 'fee_collection_monthly') {
    if (parsed.data.from) params.from = parsed.data.from;
    if (parsed.data.to) params.to = parsed.data.to;
    if (parsed.data.classId) params.class_id = parsed.data.classId;
  }
  if (parsed.data.datasetKey === 'fee_defaulters') {
    if (parsed.data.classId) params.class_id = parsed.data.classId;
    if (parsed.data.bucket) params.bucket = parsed.data.bucket;
    if (parsed.data.hideHardship) params.hide_hardship = true;
  }

  const h = await headers();
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('request_report_export', {
    p_dataset_key: parsed.data.datasetKey,
    p_params: params,
    p_reason: parsed.data.reason || undefined,
    p_ip: clientIpFromHeaders(h) ?? undefined,
  });
  if (error) return { error: mapError(error.message) };
  const result = responseSchema.safeParse(data);
  if (!result.success) return { error: 'Unexpected response from the server.' };

  // Nudge the worker so the file usually arrives within seconds; the request
  // itself never waits for it. A scheduled caller is the real guarantee.
  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = h.get('host');
  if (secret && host && !result.data.deduplicated) {
    const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
    void fetch(`${proto}://${host}/api/internal/exports/run`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
  }

  revalidatePath('/reports/exports');
  return { error: null, jobId: result.data.job_id, deduplicated: result.data.deduplicated };
}
