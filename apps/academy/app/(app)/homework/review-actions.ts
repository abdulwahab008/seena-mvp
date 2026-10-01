'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { bulkCheckSchema, checkSubmissionSchema, type BulkCheckInput, type CheckSubmissionInput } from '@/lib/validation';

export type ReviewResult = { error: string | null; count?: number };

function mapError(message: string, details: string | null | undefined): string {
  if (message.includes('SCORE_EXCEEDS_MAX')) return `Score cannot exceed the maximum of ${/max=([\d.]+)/.exec(details ?? '')?.[1] ?? 'this assignment'}`;
  if (message.includes('SCORE_NOT_ENABLED')) return 'Set a maximum score for this assignment before giving scores.';
  if (message.includes('SCORE_NEGATIVE')) return 'Score cannot be negative';
  if (message.includes('FEEDBACK_REQUIRED')) return 'Choose a feedback';
  if (message.includes('REMARK_TOO_LONG')) return 'Remark can be at most 500 characters';
  if (message.includes('SUBMISSION_NOT_SUBMITTED')) return 'This submission is not complete yet.';
  if (message.includes('EXISTING_SCORE_EXCEEDS_MAX')) return 'A score already given is higher than that maximum.';
  if (message.includes('FORBIDDEN')) return 'You are not assigned to this section and subject.';
  return 'Something went wrong. Please try again.';
}

export async function checkSubmission(input: CheckSubmissionInput): Promise<ReviewResult> {
  const p = checkSubmissionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('check_submission', { p_submission_id: p.data.submissionId, p_feedback_code: p.data.feedbackCode, p_remark: p.data.remark || undefined, p_score: p.data.score ?? undefined });
  if (error) return { error: mapError(error.message, error.details) };
  revalidatePath('/homework');
  return { error: null };
}

export async function bulkCheck(input: BulkCheckInput): Promise<ReviewResult> {
  const p = bulkCheckSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('bulk_check_submissions', { p_homework_id: p.data.homeworkId, p_submission_ids: p.data.submissionIds, p_feedback_code: p.data.feedbackCode, p_remark: p.data.remark || undefined });
  if (error) return { error: mapError(error.message, error.details) };
  revalidatePath('/homework');
  return { error: null, count: z.number().parse(data) };
}

export async function setMaxScore(homeworkId: string, maxScore: number | null): Promise<ReviewResult> {
  if (!z.string().uuid().safeParse(homeworkId).success) return { error: 'Invalid assignment.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_homework_max_score', { p_homework_id: homeworkId, p_max_score: maxScore ?? undefined });
  if (error) return { error: mapError(error.message, error.details) };
  revalidatePath('/homework');
  return { error: null };
}
