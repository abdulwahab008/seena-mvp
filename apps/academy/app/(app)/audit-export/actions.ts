'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { requestAuditExportSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type TriggerAuditExportState = {
  error: string | null;
  jobId?: string;
  rowCount?: number;
  downloadUrl?: string;
};

type AuditLogRow = {
  id: string;
  occurred_at: string;
  [key: string]: unknown;
};

// FR-T14 AC4: no queue/worker/pg_cron exists in this environment to run
// this off the request/response cycle — see the migration's own header
// for why the seam (request_audit_export / complete_audit_export /
// fail_audit_export) is what a real background worker would sit behind,
// with this loop swapped for "enqueue, let the worker call
// complete_audit_export() when done". What IS real here: the fetch below
// is keyset-paginated (occurred_at, id) against a plain RLS-governed
// SELECT — never an OFFSET scan — so it never holds more than one page in
// memory regardless of how many rows exist in total, and it's the exact
// query a real worker would run too. It runs from the authenticated
// requester's own session throughout (never a service-role client),
// exactly like FR-A18's branding upload — audit_log's own campus-scoped
// RLS (this migration's own AC3 fix) is what makes a Principal's
// out-of-scope request come back with row_count 0 instead of every row.
const PAGE_SIZE = 5000;

export async function triggerAuditExport(_prev: TriggerAuditExportState, formData: FormData): Promise<TriggerAuditExportState> {
  const parsed = requestAuditExportSchema.safeParse({
    from: formData.get('from'),
    to: formData.get('to'),
    tableNames: formData.getAll('tableNames'),
    campusId: formData.get('campusId') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: jobId, error: requestError } = await supabase.rpc('request_audit_export', {
    p_from: parsed.data.from,
    p_to: parsed.data.to,
    p_table_names: parsed.data.tableNames,
    p_campus_id: parsed.data.campusId || undefined,
  });
  if (requestError || !jobId) {
    if (requestError?.message.includes('FORBIDDEN')) return { error: 'You do not have permission to export the audit trail.' };
    if (requestError?.message.includes('INVALID_DATE_RANGE')) return { error: 'End date must be on or after the start date.' };
    if (requestError?.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    return { error: 'Could not start the export.' };
  }

  const { data: jobRow } = await supabase.from('audit_export_job').select('tenant_id').eq('id', jobId).single();
  const tenantId = jobRow?.tenant_id as string | undefined;
  if (!tenantId) {
    await supabase.rpc('fail_audit_export', { p_job_id: jobId, p_error: 'job row not found after creation' });
    return { error: 'Could not start the export.' };
  }

  const toExclusive = new Date(`${parsed.data.to}T00:00:00Z`);
  toExclusive.setUTCDate(toExclusive.getUTCDate() + 1);

  const lines: string[] = [];
  let cursor: { occurredAt: string; id: string } | null = null;
  let rowCount = 0;

  for (;;) {
    let query = supabase
      .from('audit_log')
      .select(
        'id, tenant_id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id, before, after, changed_columns',
      )
      .in('table_name', parsed.data.tableNames)
      .gte('occurred_at', parsed.data.from)
      .lt('occurred_at', toExclusive.toISOString())
      .order('occurred_at', { ascending: true })
      .order('id', { ascending: true })
      .limit(PAGE_SIZE);

    if (parsed.data.campusId) query = query.eq('campus_id', parsed.data.campusId);
    if (cursor) {
      query = query.or(`occurred_at.gt.${cursor.occurredAt},and(occurred_at.eq.${cursor.occurredAt},id.gt.${cursor.id})`);
    }

    const { data: page, error: pageError } = await query;
    if (pageError) {
      await supabase.rpc('fail_audit_export', { p_job_id: jobId, p_error: pageError.message });
      return { error: 'Export failed while reading the audit trail.' };
    }
    const rows = (page ?? []) as AuditLogRow[];
    if (rows.length === 0) break;

    for (const row of rows) lines.push(JSON.stringify(row));
    rowCount += rows.length;
    const last = rows[rows.length - 1];
    if (!last) break;
    cursor = { occurredAt: last.occurred_at, id: last.id };
    if (rows.length < PAGE_SIZE) break;
  }

  const dataContent = lines.length > 0 ? lines.join('\n') + '\n' : '';
  const dataBytes = Buffer.from(dataContent, 'utf8');
  const dataSha256 = createHash('sha256').update(dataBytes).digest('hex');

  const manifest = {
    generated_at: new Date().toISOString(),
    job_id: jobId,
    filters: {
      from: parsed.data.from,
      to: parsed.data.to,
      table_names: parsed.data.tableNames,
      campus_id: parsed.data.campusId || null,
    },
    row_count: rowCount,
    files: [{ name: 'audit_export.jsonl', bytes: dataBytes.length, sha256: dataSha256 }],
  };
  const manifestBytes = Buffer.from(JSON.stringify(manifest, null, 2), 'utf8');

  const prefix = `${tenantId}/${jobId}`;
  const dataPath = `${prefix}/audit_export.jsonl`;
  const manifestPath = `${prefix}/manifest.json`;

  const { error: uploadDataError } = await supabase.storage
    .from('audit-exports')
    .upload(dataPath, dataBytes, { contentType: 'application/x-ndjson', upsert: true });
  if (uploadDataError) {
    await supabase.rpc('fail_audit_export', { p_job_id: jobId, p_error: uploadDataError.message });
    return { error: 'Export failed while writing the export file.' };
  }

  const { error: uploadManifestError } = await supabase.storage
    .from('audit-exports')
    .upload(manifestPath, manifestBytes, { contentType: 'application/json', upsert: true });
  if (uploadManifestError) {
    await supabase.rpc('fail_audit_export', { p_job_id: jobId, p_error: uploadManifestError.message });
    return { error: 'Export failed while writing the manifest.' };
  }

  const { data: signed, error: signError } = await supabase.storage.from('audit-exports').createSignedUrl(dataPath, 60 * 60 * 24);
  if (signError || !signed) {
    await supabase.rpc('fail_audit_export', { p_job_id: jobId, p_error: signError?.message ?? 'could not create signed url' });
    return { error: 'Export failed while creating the download link.' };
  }

  const { error: completeError } = await supabase.rpc('complete_audit_export', {
    p_job_id: jobId,
    p_row_count: rowCount,
    p_manifest: manifest,
    p_storage_prefix: prefix,
    p_download_url: signed.signedUrl,
    p_expires_hours: 24,
  });
  if (completeError) return { error: 'Export finished but could not be recorded.' };

  revalidatePath('/audit-export');
  return { error: null, jobId, rowCount, downloadUrl: signed.signedUrl };
}
