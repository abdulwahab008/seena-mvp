'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import {
  MAX_IMPORT_FILE_SIZE,
  chunkRows,
  parseCsv,
  toRawRows,
  toStagePayload,
  validateImportHeader,
  validateStudentImportRows,
  type ClassOption,
} from '@/lib/student-import';

export type ValidateImportState = { error: string | null; batchId: string | null };

/**
 * FR-C14: upload a register, validate every row, write nothing.
 *
 * Nothing in this action can create a student — it only ever calls
 * create_import_batch / stage_import_rows / finalise_import_batch, none
 * of which touch public.student, gr_sequence or gr_ledger. Committing is
 * FR-C15.
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
