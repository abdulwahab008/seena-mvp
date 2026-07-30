'use server';

import { revalidatePath } from 'next/cache';
import { createSessionSchema, termsSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.includes('SESSION_OVERLAP')) return 'This date range overlaps an existing session by more than 90 days.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Session not found.';
  if (message.includes('TERM_LOCKED')) return 'Terms cannot be edited once results have been published for this session.';
  if (message.includes('TERM_COUNT_INVALID')) return 'Define between 1 and 4 terms.';
  if (message.includes('TERM_WEIGHTAGE_SUM')) return 'Term weightages must sum to exactly 100.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Something went wrong.';
}

export async function createSession(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createSessionSchema.safeParse({
    name: formData.get('name'),
    startsOn: formData.get('startsOn'),
    endsOn: formData.get('endsOn'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_academic_session', {
    p_campus_id: campusId,
    p_name: parsed.data.name,
    p_starts_on: parsed.data.startsOn,
    p_ends_on: parsed.data.endsOn,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/sessions');
  return { error: null };
}

export async function markCurrent(sessionId: string): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_current_session', { p_session_id: sessionId });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/sessions');
  return { error: null };
}

export async function saveTerms(sessionId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const raw = formData.get('terms');
  const parsed = termsSchema.safeParse({ terms: raw ? JSON.parse(raw as string) : [] });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_academic_terms', {
    p_session_id: sessionId,
    p_terms: parsed.data.terms.map((t) => ({ name: t.name, starts_on: t.startsOn, ends_on: t.endsOn, weightage: t.weightage })),
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/sessions');
  return { error: null };
}
