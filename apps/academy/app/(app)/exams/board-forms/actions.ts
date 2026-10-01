'use server';

import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import {
  boardExamError,
  boardExamFormFileName,
  buildBoardExamFormCsv,
  type BoardExamFormRow,
  type ExportReadiness,
  type Reconciliation,
} from '@/lib/board-exam-form';
import { boardExamExportSchema, boardFeeScheduleSchema, examRegistrationSchema } from '@/lib/validation';

/**
 * FR-T12. Fee schedule, registrations, the readiness-and-reconciliation check,
 * and the file. The "generate-board-exam-form-export" the FR names runs here in
 * the app server (this repo has no edge runtime), in FR-T11's order: begin ->
 * validate -> read the rows the database computed -> write the CSV -> complete.
 * Nothing in this file prices a candidate.
 */
export type ActionState = { error: string | null; message?: string };
export type CheckState = { error: string | null; exportId?: string; readiness?: ExportReadiness; reconciliation?: Reconciliation };
export type GenerateState = CheckState & { downloadUrl?: string; rowCount?: number };

export async function saveFeeSchedule(input: unknown): Promise<ActionState> {
  const parsed = boardFeeScheduleSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const v = parsed.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_board_fee_schedule', {
    p_board_code: v.boardCode,
    p_session_year: v.sessionYear,
    p_candidate_category: v.candidateCategory,
    p_per_candidate: v.perCandidatePaisa,
    p_per_paper: v.perPaperPaisa,
    p_effective_from: v.effectiveFrom,
    p_note: v.note || undefined,
  });
  if (error) return { error: boardExamError(error.message) };
  revalidatePath('/exams/board-forms');
  return { error: null, message: 'Schedule saved. Exports use the version in force on each candidate’s session date.' };
}

export async function saveRegistration(input: unknown): Promise<ActionState> {
  const parsed = examRegistrationSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const v = parsed.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_exam_registration', {
    p_student_id: v.studentId,
    p_session_id: v.sessionId,
    p_board_code: v.boardCode,
    p_session_year: v.sessionYear,
    p_session_date: v.sessionDate,
    p_candidate_category: v.candidateCategory,
    p_group_code: v.groupCode ?? '',
    p_roll_no: v.rollNo ?? '',
    p_subjects: v.subjects.map((s) => ({ subject_code: s.subjectCode, election: s.election })),
  });
  if (error) return { error: boardExamError(error.message) };
  revalidatePath('/exams/board-forms');
  return { error: null, message: 'Registration saved.' };
}

async function load(supabase: Awaited<ReturnType<typeof supabaseServer>>, exportId: string, v: { campusId: string; sessionId: string; boardCode: string; sessionYear: number }) {
  const [{ data: readiness }, { data: reconciliation }] = await Promise.all([
    supabase.rpc('fn_board_exam_form_readiness', { p_export_id: exportId }),
    supabase.rpc('fn_board_exam_reconciliation', {
      p_campus_id: v.campusId,
      p_session_id: v.sessionId,
      p_board_code: v.boardCode,
      p_session_year: v.sessionYear,
    }),
  ]);
  return {
    readiness: readiness as unknown as ExportReadiness,
    reconciliation: reconciliation as unknown as Reconciliation,
  };
}

export async function checkExport(input: unknown): Promise<CheckState> {
  const parsed = boardExamExportSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const v = parsed.data;
  const supabase = await supabaseServer();
  const { data: exportId, error: beginError } = await supabase.rpc('begin_board_exam_form_export', {
    p_campus_id: v.campusId,
    p_session_id: v.sessionId,
    p_board_code: v.boardCode,
    p_session_year: v.sessionYear,
  });
  if (beginError || !exportId) return { error: boardExamError(beginError?.message ?? '') };
  const { error: validateError } = await supabase.rpc('validate_board_exam_form_export', { p_export_id: exportId as string });
  if (validateError) return { error: boardExamError(validateError.message) };
  return { error: null, exportId: exportId as string, ...(await load(supabase, exportId as string, v)) };
}

export async function generateExport(input: unknown, exportId: string): Promise<GenerateState> {
  const parsed = boardExamExportSchema.safeParse(input);
  if (!parsed.success || !exportId) return { error: 'Check the data first.' };
  const v = parsed.data;
  const supabase = await supabaseServer();

  // Re-validate immediately before writing: the dashboard may be minutes old
  // and a fee schedule or registration may have changed since.
  const { error: validateError } = await supabase.rpc('validate_board_exam_form_export', { p_export_id: exportId });
  if (validateError) return { error: boardExamError(validateError.message) };

  const [{ data: headers, error: headerError }, { data: rows, error: rowError }] = await Promise.all([
    supabase.rpc('fn_board_exam_form_headers', { p_export_id: exportId }),
    supabase.rpc('fn_board_exam_form_rows', { p_export_id: exportId }),
  ]);
  if (headerError || rowError || !headers) {
    return { error: boardExamError(headerError?.message ?? rowError?.message ?? ''), exportId, ...(await load(supabase, exportId, v)) };
  }

  const { data: run } = await supabase.from('board_exam_form_export').select('tenant_id').eq('id', exportId).single();
  if (!run) return { error: 'Could not read the export run.' };

  const content = buildBoardExamFormCsv(headers as unknown as string[], (rows ?? []) as unknown as BoardExamFormRow[]);
  const checksum = createHash('sha256').update(Buffer.from(content, 'utf8')).digest('hex');
  const filePath = `${run.tenant_id}/${exportId}/${boardExamFormFileName(v.boardCode, v.sessionYear, exportId)}`;

  const { error: uploadError } = await supabase.storage
    .from('board-exports')
    .upload(filePath, Buffer.from(content, 'utf8'), { contentType: 'text/csv', upsert: true });
  if (uploadError) {
    await supabase.rpc('fail_board_exam_form_export', { p_export_id: exportId, p_error: uploadError.message });
    return { error: 'Could not write the export file.' };
  }
  const { data: signed, error: signError } = await supabase.storage.from('board-exports').createSignedUrl(filePath, 60 * 60 * 24);
  if (signError || !signed) {
    await supabase.rpc('fail_board_exam_form_export', { p_export_id: exportId, p_error: signError?.message ?? 'no signed url' });
    return { error: 'Could not create the download link.' };
  }

  const rowCount = (rows as unknown as unknown[] | null)?.length ?? 0;
  const { error: completeError } = await supabase.rpc('complete_board_exam_form_export', {
    p_export_id: exportId,
    p_row_count: rowCount,
    p_file_path: filePath,
    p_checksum: checksum,
  });
  if (completeError) return { error: boardExamError(completeError.message), exportId };

  revalidatePath('/exams/board-forms');
  return { error: null, exportId, rowCount, downloadUrl: signed.signedUrl, ...(await load(supabase, exportId, v)) };
}

export type StudentMatch = { id: string; name: string; gr: string };
export async function findStudents(query: string): Promise<StudentMatch[]> {
  const q = query.trim().replace(/[%,()]/g, ' ');
  if (q.length < 2) return [];
  const supabase = await supabaseServer();
  const { data } = await supabase
    .from('student')
    .select('id, name_en, gr_number')
    .or(`name_en.ilike.%${q}%,gr_number.ilike.%${q}%`)
    .is('deleted_at', null)
    .order('name_en')
    .limit(10);
  return (data ?? []).map((s) => ({ id: s.id, name: s.name_en, gr: s.gr_number }));
}
