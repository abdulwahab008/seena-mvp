'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { examTermError } from '@/lib/exams/errors';
import { activateExamTermsSchema, examTermIdSchema, upsertExamTermSchema } from '@/lib/validation';

/**
 * FR-I01. Nothing here writes to exam_term directly: the table has a SELECT
 * policy and no write policy, so a direct insert or update from a client
 * connection reaches no row at all. upsert_exam_term(),
 * activate_exam_terms(), set_exam_term_weight(), lock_exam_term() and
 * delete_exam_term() own every transition.
 */

const PATH = '/exams/terms';

export type ExamTermState = { error: string | null };
export type ActivateState = { error: string | null; activated?: number };

export async function upsertExamTerm(_prev: ExamTermState, formData: FormData): Promise<ExamTermState> {
  const parsed = upsertExamTermSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    code: formData.get('code'),
    name: formData.get('name'),
    nameUr: formData.get('nameUr') ?? '',
    sequence: formData.get('sequence'),
    weightPct: formData.get('weightPct'),
    countsTowardAnnual: formData.get('countsTowardAnnual') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_exam_term', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_code: parsed.data.code,
    p_name: parsed.data.name,
    p_sequence: parsed.data.sequence,
    p_weight_pct: parsed.data.weightPct,
    p_counts_toward_annual: parsed.data.countsTowardAnnual,
    p_name_ur: parsed.data.nameUr || undefined,
  });
  if (error) return { error: examTermError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}

/**
 * AC2: when the counting terms do not total 100.00%, the database refuses
 * and the sentence it refuses with is shown to the Exam Controller word for
 * word — see lib/exams/errors.ts for why it is not paraphrased.
 */
export async function activateExamTerms(_prev: ActivateState, formData: FormData): Promise<ActivateState> {
  const parsed = activateExamTermsSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('activate_exam_terms', {
    p_session_id: parsed.data.sessionId,
    p_campus_id: parsed.data.campusId,
  });
  if (error) return { error: examTermError(error.message) };

  revalidatePath(PATH);
  return { error: null, activated: data ?? 0 };
}

export async function deleteExamTerm(formData: FormData): Promise<ExamTermState> {
  const parsed = examTermIdSchema.safeParse({ examTermId: formData.get('examTermId') });
  if (!parsed.success) return { error: 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_exam_term', { p_exam_term_id: parsed.data.examTermId });
  if (error) return { error: examTermError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}

/**
 * The FR-I16 seam, exposed so the AC3 freeze is demonstrable before mark
 * approval exists. Once FR-I16 ships, approving a mark set calls
 * lock_exam_term() itself and this control comes off the setup screen.
 */
export async function lockExamTerm(formData: FormData): Promise<ExamTermState> {
  const parsed = examTermIdSchema.safeParse({ examTermId: formData.get('examTermId') });
  if (!parsed.success) return { error: 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('lock_exam_term', { p_exam_term_id: parsed.data.examTermId });
  if (error) return { error: examTermError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}
