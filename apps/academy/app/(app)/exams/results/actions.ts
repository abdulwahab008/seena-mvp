'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { subjectResultError } from '@/lib/exams/errors';
import type { SubjectResultSheet } from '@/lib/exams/result-query';
import { computeSubjectResultSchema } from '@/lib/validation';

/**
 * FR-J02. Two calls, and the split is the requirement's:
 *
 *   readResultSheet()      shows what has already been computed, including
 *                          whether a break-glass edit has made it stale;
 *   computeSubjectResults() is the explicit recompute, and the only thing on
 *                          this screen that writes.
 *
 * Ordinary computation is not either of these — approving the last paper of a
 * section fires trg_enqueue_result_compute and the results are simply there.
 * This button exists for the correction case.
 */
export type ResultSheetState = { error: string | null; sheet?: SubjectResultSheet };
export type ComputeResultState = { error: string | null; rows?: number };

export async function readResultSheet(examTermId: string, sectionId: string): Promise<ResultSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_subject_result_sheet', {
    p_exam_term_id: examTermId,
    p_section_id: sectionId,
  });
  if (error || !data) {
    return { error: error ? subjectResultError(error.message) : 'Could not read the results.' };
  }
  return { error: null, sheet: data as unknown as SubjectResultSheet };
}

export async function computeSubjectResults(input: unknown): Promise<ComputeResultState> {
  const parsed = computeSubjectResultSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_compute_subject_result', {
    p_exam_term_id: parsed.data.examTermId,
    p_section_id: parsed.data.sectionId,
  });
  if (error) return { error: subjectResultError(error.message) };

  return { error: null, rows: data ?? 0 };
}
