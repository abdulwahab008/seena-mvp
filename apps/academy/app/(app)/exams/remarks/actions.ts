'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { applyRemarkSchema, libraryEntrySchema, remarkSchema, type ApplyRemarkInput, type LibraryEntryInput, type RemarkInput } from '@/lib/validation';

type Result = { error: string | null; count?: number };

function mapError(message: string): string {
  if (message.includes('REMARK_TOO_LONG')) return 'A remark can be at most 250 characters.';
  if (message.includes('REMARK_EMPTY')) return 'Write a remark first.';
  if (message.includes('FORBIDDEN')) return 'Only this section\'s class teacher or the Principal can write remarks.';
  if (message.includes('LIBRARY_ENTRY_NOT_FOUND')) return 'That library remark no longer exists.';
  return 'Something went wrong. Please try again.';
}

export async function saveRemark(input: RemarkInput): Promise<Result> {
  const r = remarkSchema.safeParse(input);
  if (!r.success) return { error: r.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_term_remark', { p_enrolment_id: r.data.enrolmentId, p_exam_term_id: r.data.examTermId, p_text: r.data.text, p_library_id: r.data.libraryId || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/exams/remarks');
  return { error: null };
}

export async function applyRemark(input: ApplyRemarkInput): Promise<Result> {
  const r = applyRemarkSchema.safeParse(input);
  if (!r.success) return { error: r.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('apply_term_remark', { p_exam_term_id: r.data.examTermId, p_enrolment_ids: r.data.enrolmentIds, p_text: r.data.text, p_library_id: r.data.libraryId || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/exams/remarks');
  return { error: null, count: data as number };
}

export async function addLibraryEntry(campusId: string, input: LibraryEntryInput): Promise<Result> {
  const e = libraryEntrySchema.safeParse(input);
  if (!z.string().uuid().safeParse(campusId).success || !e.success) return { error: e.success ? 'Invalid campus.' : (e.error.issues[0]?.message ?? 'Invalid input.') };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_remark_library_entry', { p_campus_id: campusId, p_category: e.data.category, p_text_en: e.data.textEn, p_text_ur: e.data.textUr || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/exams/remarks');
  return { error: null };
}

export async function seedLibrary(campusId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Invalid campus.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('seed_default_remark_library', { p_campus_id: campusId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/exams/remarks');
  return { error: null, count: data as number };
}

export async function setRemarksRequired(campusId: string, required: boolean): Promise<Result> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Invalid campus.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_remarks_required', { p_campus_id: campusId, p_required: required });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/exams/remarks');
  return { error: null };
}
