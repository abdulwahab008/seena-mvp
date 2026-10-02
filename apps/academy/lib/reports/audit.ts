import { headers } from 'next/headers';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';

export type ReportRun = {
  reportKey: string;
  datasetKey: string;
  columns: string[];
  filters: Record<string, unknown>;
  rowCount: number;
  reason?: string | null;
  destination: 'screen' | 'csv' | 'xlsx' | 'pdf' | 'api';
};

// Every report run and export must pass through here. The database decides
// whether the run is PII-bearing and refuses a PII export without a reason.
export async function recordReportRun(run: ReportRun): Promise<{ error: string | null; auditId?: string }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('record_report_run', {
    p_report_key: run.reportKey,
    p_dataset_key: run.datasetKey,
    p_columns: run.columns,
    p_filters: run.filters as never,
    p_row_count: run.rowCount,
    p_reason: run.reason ?? undefined,
    p_destination: run.destination,
    p_ip: clientIpFromHeaders(await headers()) ?? undefined,
  });
  if (error) {
    if (error.message.includes('REASON_REQUIRED_FOR_PII_EXPORT')) return { error: 'This export contains personal data. Give a reason of at least 20 characters.' };
    return { error: 'Could not record the export.' };
  }
  return { error: null, auditId: data };
}
