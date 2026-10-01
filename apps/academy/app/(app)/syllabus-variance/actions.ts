'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { varianceAckSchema, type VarianceAckInput } from '@/lib/validation';

type Result = { error: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only the Principal, Exam Controller or Owner can do this for this campus.';
  if (message.includes('REASON_REQUIRED')) return 'Enter a reason of at least 3 characters.';
  return 'Something went wrong. Please try again.';
}

export async function refreshVariance(campusId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Invalid campus.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('refresh_syllabus_variance', { p_campus_id: campusId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/syllabus-variance');
  return { error: null };
}

export async function acknowledgeVariance(input: VarianceAckInput): Promise<Result> {
  const p = varianceAckSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('acknowledge_syllabus_variance', { p_section_id: p.data.sectionId, p_subject_id: p.data.subjectId, p_reason: p.data.reason });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/syllabus-variance');
  return { error: null };
}

export async function clearAcknowledgement(sectionId: string, subjectId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(sectionId).success || !z.string().uuid().safeParse(subjectId).success) return { error: 'Invalid selection.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('clear_syllabus_variance_ack', { p_section_id: sectionId, p_subject_id: subjectId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/syllabus-variance');
  return { error: null };
}
