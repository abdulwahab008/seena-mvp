'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import type { Json } from '@/lib/database.types';
import {
  MAX_IMPORT_FILE_SIZE,
  buildFailureReportCsv,
  chunkRows,
  parseCsv,
  toRawRows,
  toStagePayload,
  validateImportHeader,
  validateStudentImportRows,
  type ClassOption,
  type FailureReportRow,
  type ImportIssue,
} from '@/lib/student-import';

export type ValidateImportState = { error: string | null; batchId: string | null };

/**
 * FR-C14: upload a register, validate every row, write nothing.
 *
 * Nothing in this action can create a student — it only ever calls
 * create_import_batch / stage_import_rows / finalise_import_batch, none
 * of which touch public.student, gr_sequence or gr_ledger. Committing is
 * commitStudentImport() below (FR-C15).
 */
export async function validateStudentImport(_prev: ValidateImportState, formData: FormData): Promise<ValidateImportState> {
  const file = formData.get('file');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose a CSV file to validate.', batchId: null };
  if (file.size > MAX_IMPORT_FILE_SIZE) return { error: 'Maximum file size 10 MB.', batchId: null };

  const campusId = String(formData.get('campusId') ?? '');
  const sessionId = String(formData.get('sessionId') ?? '');
  if (!campusId || !sessionId) return { error: 'Choose a campus and an academic session.', batchId: null };

  const matrix = parseCsv(await file.text());
  if (matrix.length === 0) return { error: 'That file is empty.', batchId: null };

  // AC: a header set that does not match the published template is
  // rejected before parsing — no batch row, nothing uploaded, no report.
  const header = validateImportHeader(matrix[0]!);
  if (!header.ok) return { error: header.message, batchId: null };

  const rows = toRawRows(matrix, header.columns);
  if (rows.length === 0) return { error: 'That file has a header but no rows to import.', batchId: null };

  const supabase = await supabaseServer();
  const { data: classes } = await supabase.from('class_level').select('id, code, name_en').eq('is_active', true).order('ordinal');
  const validated = validateStudentImportRows(rows, (classes ?? []) as ClassOption[]);

  const { data: batch, error: batchError } = await supabase.rpc('create_import_batch', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_original_filename: file.name,
  });
  if (batchError) {
    if (batchError.message.includes('FORBIDDEN')) return { error: 'You do not have permission to import students at this campus.', batchId: null };
    if (batchError.message.includes('SESSION_NOT_FOUND')) return { error: 'That academic session does not belong to this campus.', batchId: null };
    return { error: 'Could not start the validation run.', batchId: null };
  }

  const { batch_id: batchId, file_path: filePath } = batch as unknown as { batch_id: string; file_path: string };

  const { error: uploadError } = await supabase.storage
    .from('imports')
    .upload(filePath, file, { contentType: 'text/csv', upsert: false });
  if (uploadError) return { error: 'The file failed to upload. Please try again.', batchId: null };

  for (const chunk of chunkRows(toStagePayload(validated))) {
    const { error } = await supabase.rpc('stage_import_rows', { p_batch_id: batchId, p_rows: chunk });
    if (error) return { error: 'Validation stopped part-way through the file. Please try again.', batchId: null };
  }

  const { error: finaliseError } = await supabase.rpc('finalise_import_batch', { p_batch_id: batchId });
  if (finaliseError) return { error: 'Could not finish validating the file.', batchId: null };

  revalidatePath('/students/import');
  return { error: null, batchId };
}

// ── FR-C15: commit, failure report, undo ─────────────────────────────────

export type CommitImportResult = {
  error: string | null;
  ok: boolean;
  committedRows: number;
  failedRowNo: number | null;
  failedMessage: string | null;
};

type CommitPayload = {
  ok: boolean;
  committed_rows: number;
  failed_row_no: number | null;
  message: string | null;
  error_report_path: string | null;
};

function toFailureRows(rows: Array<{ row_no: number; raw: Json; errors: Json }>): FailureReportRow[] {
  return rows.map((row) => {
    const raw: Record<string, string> = {};
    if (row.raw && typeof row.raw === 'object' && !Array.isArray(row.raw)) {
      for (const [column, value] of Object.entries(row.raw)) raw[column] = typeof value === 'string' ? value : '';
    }
    const errors: ImportIssue[] = (Array.isArray(row.errors) ? row.errors : []).map((entry) => {
      const issue = entry as { column?: string; code?: string; severity?: string; message?: string };
      return {
        column: issue.column ?? '',
        code: issue.code ?? '',
        severity: issue.severity === 'warning' ? 'warning' : 'error',
        message: issue.message ?? '',
      };
    });
    return { rowNo: row.row_no, raw, errors };
  });
}

/**
 * FR-C15: commit the validated rows all-or-nothing, then write the report
 * of the rows that never made it.
 *
 * Everything transactional happens inside commit_import_batch(); this
 * action's only job afterwards is turning the blocked rows into the CSV
 * the school takes away. A commit that fails mid-file comes back as
 * ok:false with the offending row — not as an error — because the
 * database has already recorded the failure on the batch and rolled every
 * write back.
 */
export async function commitStudentImport(batchId: string): Promise<CommitImportResult> {
  const empty = { ok: false, committedRows: 0, failedRowNo: null, failedMessage: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('commit_import_batch', { p_batch_id: batchId });
  if (error) {
    if (error.message.includes('ALREADY_COMMITTED')) return { ...empty, error: 'This file has already been imported.' };
    if (error.message.includes('IMPORT_BATCH_UNDONE')) return { ...empty, error: 'This import was undone. Upload the file again to retry.' };
    if (error.message.includes('NOT_VALIDATED')) return { ...empty, error: 'Validate this file before importing it.' };
    if (error.message.includes('NO_IMPORTABLE_ROWS')) return { ...empty, error: 'Every row in this file is blocked — there is nothing to import.' };
    if (error.message.includes('FORBIDDEN')) return { ...empty, error: 'You do not have permission to import students at this campus.' };
    return { ...empty, error: 'The import could not be started.' };
  }

  const result = data as unknown as CommitPayload;

  if (result.error_report_path) {
    const { data: blocked } = await supabase
      .from('import_row')
      .select('row_no, raw, errors')
      .eq('batch_id', batchId)
      .eq('severity', 'error')
      .order('row_no');

    await supabase.storage
      .from('import-errors')
      .upload(result.error_report_path, buildFailureReportCsv(toFailureRows(blocked ?? [])), {
        contentType: 'text/csv',
        upsert: true,
      });
  }

  revalidatePath('/students/import');

  if (!result.ok) {
    return { error: null, ok: false, committedRows: 0, failedRowNo: result.failed_row_no, failedMessage: result.message };
  }
  return { error: null, ok: true, committedRows: result.committed_rows, failedRowNo: null, failedMessage: null };
}

/**
 * FR-C15 AC5: take the whole import back, within 24 hours and only while
 * nothing depends on it. Both gates live in undo_import_batch(); this
 * action only translates their error codes.
 */
export async function undoStudentImport(batchId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('undo_import_batch', { p_batch_id: batchId });
  if (error) {
    if (error.message.includes('UNDO_WINDOW_EXPIRED')) {
      return { error: 'The 24-hour window for undoing this import has closed.' };
    }
    if (error.message.includes('UNDO_BLOCKED_BY_DEPENDENCY')) {
      return { error: 'These students already have fee or attendance records, so the import can no longer be undone.' };
    }
    if (error.message.includes('NOT_COMMITTED')) return { error: 'This import has not been committed.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can undo an import.' };
    return { error: 'The import could not be undone.' };
  }

  revalidatePath('/students/import');
  return { error: null };
}
