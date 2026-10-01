import type { SupabaseClient } from '@supabase/supabase-js';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { dispatchDueJobs } from './paper-worker';

export type PaperRequestInput = {
  examSubjectId: string;
  boardPatternId: string;
  chapters: string[];
  totalMarks: number;
  setCount: number;
};

export function paperRequestError(message: string, details?: string | null): string {
  if (message.includes('PATTERN_TOTAL_MISMATCH')) return details ?? 'The total marks do not match the pattern.';
  if (message.includes('CHAPTERS_REQUIRED')) return 'Choose at least one chapter.';
  if (message.includes('PATTERN_NOT_FOUND')) return 'That board pattern is not available.';
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'Exam subject not found.';
  if (message.includes('SET_COUNT_INVALID')) return 'A paper is generated in 1 to 4 sets.';
  if (message.includes('JOB_NOT_FOUND')) return 'Job not found.';
  if (message.includes('JOB_NOT_FAILED')) return 'Only a failed job can be retried.';
  if (message.includes('PATTERN_SECTIONS_INVALID')) return 'Each section needs a type (MCQ, short or long), a count and marks per question.';
  if (message.includes('PATTERN_NAME_REQUIRED')) return 'A pattern needs a code and a name.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}

/**
 * Writes the job row (status 'queued', returned to the caller at once) and then
 * nudges the dispatcher. The nudge is deliberately not awaited: the caller gets
 * its job card in milliseconds, and if the nudge is lost the cron endpoint
 * picks the job up from the queue.
 */
export async function createPaperJob(supabase: SupabaseClient, input: PaperRequestInput): Promise<{ jobId: string | null; error: string | null }> {
  const { data, error } = await supabase.rpc('request_paper_generation', {
    p_exam_subject_id: input.examSubjectId,
    p_board_pattern_id: input.boardPatternId,
    p_chapters: input.chapters,
    p_total_marks: input.totalMarks,
    p_set_count: input.setCount,
  });
  if (error) return { jobId: null, error: paperRequestError(error.message, error.details) };
  void dispatchDueJobs(supabaseServiceRole()).catch(() => undefined);
  return { jobId: data as string, error: null };
}
