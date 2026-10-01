'use server';

import { headers } from 'next/headers';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import { drilldownExportSchema, type DrilldownExportInput } from '@/lib/validation';

const DATASET = { outstanding: 'drilldown_outstanding', absentees: 'drilldown_absentees', staff_cost: 'drilldown_staff_cost' } as const;
const responseSchema = z.object({ job_id: z.string().uuid(), deduplicated: z.boolean() });

export type DrilldownExportResult = { error: string } | { error: null; jobId: string };

// The drill-down passes the filter set it is showing straight to the export job:
// the user never re-selects anything.
export async function exportDrilldown(input: DrilldownExportInput): Promise<DrilldownExportResult> {
  const parsed = drilldownExportSchema.safeParse(input);
  if (!parsed.success) return { error: 'Invalid request.' };
  const params: Record<string, string> = {};
  if (parsed.data.campusId) params.campus_id = parsed.data.campusId;
  if (parsed.data.bucket) params.bucket = parsed.data.bucket;
  if (parsed.data.onDay) params.on_day = parsed.data.onDay;

  const h = await headers();
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('request_report_export', {
    p_dataset_key: DATASET[parsed.data.metric],
    p_params: params,
    p_ip: clientIpFromHeaders(h) ?? undefined,
  });
  if (error) return { error: error.message.includes('DATASET_NOT_AVAILABLE') ? 'You do not have access to this export.' : 'Could not queue the export. Please try again.' };
  const result = responseSchema.safeParse(data);
  if (!result.success) return { error: 'Unexpected response from the server.' };

  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = h.get('host');
  if (secret && host && !result.data.deduplicated) {
    const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
    void fetch(`${proto}://${host}/api/internal/exports/run`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
  }
  return { error: null, jobId: result.data.job_id };
}
