'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { resitError, type ResitSheet } from '@/lib/exams/resit-query';
import {
  generateResitListSchema,
  grantResitExceptionSchema,
  recordAttemptSchema,
  setResitPolicySchema,
} from '@/lib/validation';

/** FR-J14. Every action is one RPC; the substitution rule lives in the database. */
export type ResitSheetState = { error: string | null; sheet?: ResitSheet };
export type ResitActionState = { error: string | null; message?: string };

export async function readResitSheet(examTermId: string): Promise<ResitSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_resit_sheet', { p_exam_term_id: examTermId });
  if (error || !data) return { error: error ? resitError(error.message) : 'Could not read the re-sit list.' };
  return { error: null, sheet: data as unknown as ResitSheet };
}

export async function generateResitList(input: unknown): Promise<ResitActionState> {
  const parsed = generateResitListSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_generate_resit_eligibility_list', { p_exam_term_id: parsed.data.examTermId });
  if (error) return { error: resitError(error.message) };
  revalidatePath('/exams/resits');
  return { error: null, message: `${data ?? 0} candidate papers assessed.` };
}

export async function recordAttempt(input: unknown): Promise<ResitActionState> {
  const parsed = recordAttemptSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_exam_attempt', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_exam_subject_id: parsed.data.examSubjectId,
    p_attempt_type: parsed.data.attemptType,
    p_obtained: parsed.data.obtained,
    p_sat_on: parsed.data.satOn,
  });
  if (error) return { error: resitError(error.message) };
  revalidatePath('/exams/resits');
  return { error: null, message: 'Attempt recorded. The published result has been recomputed.' };
}

export async function grantException(input: unknown): Promise<ResitActionState> {
  const parsed = grantResitExceptionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('grant_resit_exception', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_exam_subject_id: parsed.data.examSubjectId,
    p_reason: parsed.data.reason,
  });
  if (error) return { error: resitError(error.message) };
  revalidatePath('/exams/resits');
  return { error: null, message: 'Exception recorded.' };
}

export async function setPolicy(input: unknown): Promise<ResitActionState> {
  const parsed = setResitPolicySchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_resit_policy', { p_campus_id: parsed.data.campusId, p_policy: parsed.data.policy });
  if (error) return { error: resitError(error.message) };
  revalidatePath('/exams/resits');
  return { error: null, message: 'Policy saved. It applies to results computed from now on.' };
}
