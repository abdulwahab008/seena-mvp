'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { moderationError } from '@/lib/exams/moderation-errors';
import { moderationSchema, reverseModerationSchema, type ModerationInput, type ReverseModerationInput } from '@/lib/validation';

/**
 * FR-I15. mark_moderation has a SELECT policy and no write policy; marks only
 * move through fn_apply_moderation() / fn_reverse_moderation(), which enforce the
 * cap, the reason, the once-only rule and the pre-approval limit themselves.
 */
const PATH = '/exams/moderation';

export type ModerationCapped = { enrolment_id: string; gr_number: string; name: string; before: number; after: number };
export type ModerationResult = { error: string | null; affected?: number; capped?: ModerationCapped[] };

export async function applyModeration(input: ModerationInput): Promise<ModerationResult> {
  const p = moderationSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_apply_moderation', {
    p_exam_subject_id: p.data.examSubjectId,
    p_section_id: p.data.sectionId,
    p_delta: p.data.delta,
    p_reason: p.data.reason,
  });
  if (error) return { error: moderationError(error.message, error.details) };
  revalidatePath(PATH);
  const result = data as unknown as { affected: number; capped: ModerationCapped[] };
  return { error: null, affected: result.affected, capped: result.capped };
}

export async function reverseModeration(input: ReverseModerationInput): Promise<{ error: string | null; restored?: number; skipped?: number }> {
  const p = reverseModerationSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_reverse_moderation', { p_moderation_id: p.data.moderationId, p_reason: p.data.reason });
  if (error) return { error: moderationError(error.message, error.details) };
  revalidatePath(PATH);
  const result = data as unknown as { restored: number; skipped: number };
  return { error: null, restored: result.restored, skipped: result.skipped };
}
