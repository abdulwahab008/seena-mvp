'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the exam controller or Principal can handle re-checks.';
  if (m.includes('RESULT_NOT_FOUND')) return 'This student has no computed result in that subject yet.';
  if (m.includes('uq_result_recheck_open')) return 'A re-check for this subject is already open.';
  if (m.includes('MARKS_REQUIRED')) return 'Enter the corrected marks.';
  if (m.includes('RECHECK_DECIDED')) return 'This re-check is already decided.';
  return 'Something went wrong. Try again.';
}

const requestSchema = z.object({
  termId: z.string().uuid(),
  enrolmentId: z.string().uuid('Choose a student'),
  subjectId: z.string().uuid('Choose a subject'),
  fee: z.coerce.number().min(0, 'The fee cannot be negative'),
  reason: z.string().trim().min(1, 'Give a reason').max(500),
});

export async function requestRecheck(input: unknown): Promise<{ error: string | null }> {
  const p = requestSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('request_result_recheck', {
    p_exam_term_id: p.data.termId, p_enrolment_id: p.data.enrolmentId, p_subject_id: p.data.subjectId,
    p_fee_paisa: Math.round(p.data.fee * 100), p_reason: p.data.reason,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/exams/rechecks');
  return { error: null };
}

const decideSchema = z.object({ id: z.string().uuid(), changed: z.boolean(), marksAfter: z.coerce.number().min(0).nullable(), note: z.string().trim().max(500) });

export async function decideRecheck(input: unknown): Promise<{ error: string | null }> {
  const p = decideSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the outcome.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_result_recheck', {
    p_id: p.data.id, p_changed: p.data.changed, p_marks_after: p.data.changed ? (p.data.marksAfter ?? undefined) : undefined, p_note: p.data.note,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/exams/rechecks');
  return { error: null };
}
