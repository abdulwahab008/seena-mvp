'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { markUnlockError } from '@/lib/exams/errors';
import { breakGlassUnlockSchema, rejectMarkUnlockSchema, requestMarkUnlockSchema } from '@/lib/validation';

/**
 * FR-I17. Three writes, and the split between them is the control: a request
 * and a decision are separate calls made by separate people, and neither
 * function will accept the other's role.
 *
 * revalidatePath here where FR-I12's grid deliberately does not: nothing on
 * these screens is being typed under anyone's fingers, and the whole point of
 * the queue is that it shows the current state of a request the moment it
 * changes.
 */
export type UnlockActionState = { error: string | null; requestId?: string; expiresAt?: string };

export async function requestMarkUnlock(input: unknown): Promise<UnlockActionState> {
  const parsed = requestMarkUnlockSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('request_mark_unlock', {
    p_exam_subject_id: parsed.data.examSubjectId,
    p_section_id: parsed.data.sectionId,
    p_reason: parsed.data.reason,
  });
  if (error) return { error: markUnlockError(error.message) };

  revalidatePath('/exams/unlocks');
  return { error: null, requestId: (data as string) ?? undefined };
}

export async function breakGlassUnlock(input: unknown): Promise<UnlockActionState> {
  const parsed = breakGlassUnlockSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_break_glass_unlock', {
    p_request_id: parsed.data.requestId,
    p_window_minutes: parsed.data.windowMinutes,
  });
  if (error) return { error: markUnlockError(error.message) };

  revalidatePath('/exams/unlocks');
  revalidatePath('/exams/marks');
  const result = (data ?? {}) as { expires_at?: string };
  return { error: null, requestId: parsed.data.requestId, expiresAt: result.expires_at };
}

export async function rejectMarkUnlock(input: unknown): Promise<UnlockActionState> {
  const parsed = rejectMarkUnlockSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reject_mark_unlock', {
    p_request_id: parsed.data.requestId,
    ...(parsed.data.note ? { p_note: parsed.data.note } : {}),
  });
  if (error) return { error: markUnlockError(error.message) };

  revalidatePath('/exams/unlocks');
  return { error: null, requestId: parsed.data.requestId };
}

/**
 * The five-minute sweep, run by hand. It exists on the screen because the
 * window is closed by the clock and not by this button — a Principal who wants
 * to SEE a lapsed window shown as closed should not have to wait for the next
 * cron tick to believe it.
 */
export async function relockExpiredUnlocks(): Promise<{ error: string | null; relocked?: number }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_relock_expired_unlocks');
  if (error) return { error: markUnlockError(error.message) };

  revalidatePath('/exams/unlocks');
  revalidatePath('/exams/marks');
  return { error: null, relocked: (data as number) ?? 0 };
}
