'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { markApprovalError } from '@/lib/exams/errors';
import type { MarkApprovalQueue } from '@/lib/exams/mark-query';
import { approveMarksSchema } from '@/lib/validation';

/**
 * FR-I16. Two calls, and the split is the requirement's:
 *
 *   readApprovalQueue()  asks what is complete WITHOUT attempting anything, so
 *                        AC1's two GR numbers are on screen before the
 *                        controller clicks rather than as the result of a
 *                        refusal;
 *   approveMarks()       is the explicit approval action, and the only thing
 *                        that ever writes a lock.
 *
 * Neither takes a decision the database does not re-take: fn_approve_marks()
 * re-runs the completeness check inside the same transaction that writes the
 * lock, so a mark cleared between the read and the click cannot slip through.
 */
export type ApprovalQueueState = { error: string | null; queue?: MarkApprovalQueue };
export type ApproveMarksState = { error: string | null; marksLocked?: number; termLocked?: boolean };

export async function readApprovalQueue(examTermId: string, sectionId: string): Promise<ApprovalQueueState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_mark_approval_queue', {
    p_exam_term_id: examTermId,
    p_section_id: sectionId,
  });
  if (error || !data) {
    return { error: error ? markApprovalError(error.message) : 'Could not read the approval queue.' };
  }
  return { error: null, queue: data as unknown as MarkApprovalQueue };
}

export async function approveMarks(input: unknown): Promise<ApproveMarksState> {
  const parsed = approveMarksSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_approve_marks', {
    p_exam_subject_id: parsed.data.examSubjectId,
    p_section_id: parsed.data.sectionId,
  });
  if (error) return { error: markApprovalError(error.message) };

  const result = (data ?? {}) as { marks_locked?: number; term_locked?: boolean };
  return { error: null, marksLocked: result.marks_locked ?? 0, termLocked: result.term_locked ?? false };
}
