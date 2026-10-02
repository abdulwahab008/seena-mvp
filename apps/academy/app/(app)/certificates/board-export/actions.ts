'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import type { Database } from '@/lib/database.types';
import {
  boardExportFileName,
  buildBoardExportCsv,
  type BoardExportRow,
  type BoardExportRowError,
} from '@/lib/board-export';

type Board = Database['public']['Enums']['board'];

const BOARDS: readonly string[] = ['FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE'];

export type ReadinessState = {
  error: string | null;
  runId?: string;
  readiness?: Record<string, unknown>;
  errors?: BoardExportRowError[];
};

export type GenerateState = ReadinessState & { downloadUrl?: string; rowCount?: number };

// FR-T11: the run's own errors, in the order the controller works through
// them — the children who cannot go at all first.
async function loadRun(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  runId: string,
): Promise<{ readiness: Record<string, unknown>; errors: BoardExportRowError[] }> {
  const [{ data: readiness }, { data: errors }] = await Promise.all([
    supabase.rpc('fn_board_export_readiness', { p_run_id: runId }),
    supabase
      .from('board_export_row_error')
      .select('student_id, field_path, current_value, expected, rule_code, severity, normalisable')
      .eq('run_id', runId)
      .order('severity')
      .order('field_path'),
  ]);
  return {
    readiness: (readiness as Record<string, unknown>) ?? {},
    errors: (errors ?? []) as BoardExportRowError[],
  };
}

function rpcMessage(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission to run a board export for this campus.';
  if (message.includes('BOARD_AMBIGUOUS'))
    return 'This class level is split across two boards. Choose the board this file is for.';
  if (message.includes('BOARD_PROFILE_NOT_FOUND'))
    return 'No registration format is configured for that board yet.';
  if (message.includes('NO_STUDENTS_ENROLLED')) return 'Nobody is enrolled in that class level.';
  if (message.includes('EXPORT_BLOCKED')) return 'Fix every blocking error before generating the file.';
  if (message.includes('EXPORT_NOT_VALIDATED')) return 'Check the data before generating the file.';
  if (message.includes('CLASS_LEVEL_NOT_FOUND')) return 'Class level not found.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Academic session not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  return 'Could not check the registration data.';
}

export async function checkBoardExport(_prev: ReadinessState, formData: FormData): Promise<ReadinessState> {
  const campusId = String(formData.get('campusId') ?? '');
  const sessionId = String(formData.get('sessionId') ?? '');
  const classLevelId = String(formData.get('classLevelId') ?? '');
  const board = String(formData.get('board') ?? '');
  if (!campusId || !sessionId || !classLevelId) return { error: 'Choose a campus, session and class level.' };

  const supabase = await supabaseServer();
  const { data: runId, error: beginError } = await supabase.rpc('begin_board_export_run', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_class_level_id: classLevelId,
    ...(BOARDS.includes(board) ? { p_board: board as Board } : {}),
  });
  if (beginError || !runId) return { error: rpcMessage(beginError?.message ?? '') };

  const { error: validateError } = await supabase.rpc('validate_board_export', { p_run_id: runId });
  if (validateError) return { error: rpcMessage(validateError.message) };

  const loaded = await loadRun(supabase, runId as string);
  revalidatePath('/certificates/board-export');
  return { error: null, runId: runId as string, ...loaded };
}

export async function normaliseBoardExport(_prev: ReadinessState, formData: FormData): Promise<ReadinessState> {
  const runId = String(formData.get('runId') ?? '');
  if (!runId) return { error: 'No export to normalise.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('normalise_board_export_run', { p_run_id: runId });
  if (error) return { error: rpcMessage(error.message) };

  const loaded = await loadRun(supabase, runId);
  revalidatePath('/certificates/board-export');
  return { error: null, runId, ...loaded };
}

export async function generateBoardExport(_prev: GenerateState, formData: FormData): Promise<GenerateState> {
  const runId = String(formData.get('runId') ?? '');
  if (!runId) return { error: 'Check the data first.' };

  const supabase = await supabaseServer();

  // Re-validate immediately before writing. The dashboard may be minutes old
  // and a student's B-Form may have been edited since — a file generated
  // from a stale verdict is the exact thing this FR exists to prevent.
  const { error: validateError } = await supabase.rpc('validate_board_export', { p_run_id: runId });
  if (validateError) return { error: rpcMessage(validateError.message) };

  const [{ data: headers, error: headerError }, { data: rows, error: rowError }] = await Promise.all([
    supabase.rpc('fn_board_export_headers', { p_run_id: runId }),
    supabase.rpc('fn_board_export_rows', { p_run_id: runId }),
  ]);
  if (headerError || rowError || !headers) {
    const loaded = await loadRun(supabase, runId);
    return { error: rpcMessage(headerError?.message ?? rowError?.message ?? ''), runId, ...loaded };
  }

  const { data: run } = await supabase
    .from('board_export_run')
    .select('tenant_id, board_code, class_level_id, profile_id')
    .eq('id', runId)
    .single();
  if (!run) return { error: 'Could not read the export run.' };

  const [{ data: profile }, { data: classLevel }] = await Promise.all([
    supabase.from('board_profile').select('byte_order_mark').eq('id', run.profile_id).single(),
    supabase.from('class_level').select('code').eq('id', run.class_level_id).single(),
  ]);

  const content = buildBoardExportCsv(headers as string[], (rows ?? []) as BoardExportRow[], {
    byteOrderMark: profile?.byte_order_mark ?? true,
  });
  const checksum = createHash('sha256').update(Buffer.from(content, 'utf8')).digest('hex');
  const fileName = boardExportFileName(run.board_code, classLevel?.code ?? 'CLASS', runId);
  const filePath = `${run.tenant_id}/${runId}/${fileName}`;

  const { error: uploadError } = await supabase.storage
    .from('board-exports')
    .upload(filePath, Buffer.from(content, 'utf8'), { contentType: 'text/csv', upsert: true });
  if (uploadError) {
    await supabase.rpc('fail_board_export_run', { p_run_id: runId, p_error: uploadError.message });
    return { error: 'Could not write the export file.' };
  }

  const { data: signed, error: signError } = await supabase.storage
    .from('board-exports')
    .createSignedUrl(filePath, 60 * 60 * 24);
  if (signError || !signed) {
    await supabase.rpc('fail_board_export_run', { p_run_id: runId, p_error: signError?.message ?? 'no signed url' });
    return { error: 'Could not create the download link.' };
  }

  const rowCount = (rows ?? []).length;
  const { error: completeError } = await supabase.rpc('complete_board_export_run', {
    p_run_id: runId,
    p_row_count: rowCount,
    p_file_path: filePath,
    p_checksum: checksum,
  });
  if (completeError) return { error: rpcMessage(completeError.message), runId };

  revalidatePath('/certificates/board-export');
  return { error: null, runId, rowCount, downloadUrl: signed.signedUrl };
}
