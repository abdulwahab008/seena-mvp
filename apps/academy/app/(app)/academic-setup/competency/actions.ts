'use server';

import { revalidatePath } from 'next/cache';
import { declareCompetencySchema, verifyCompetencySchema, suggestSubstitutesSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-E07: HR declares (or widens) a teacher's competency range for a
// subject. declare_competency() never downgrades an already-Verified row.
export async function declareCompetency(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = declareCompetencySchema.safeParse({
    staffId: formData.get('staffId'),
    subjectId: formData.get('subjectId'),
    minClassOrdinal: formData.get('minClassOrdinal'),
    maxClassOrdinal: formData.get('maxClassOrdinal'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('declare_competency', {
    p_staff_id: parsed.data.staffId,
    p_subject_id: parsed.data.subjectId,
    p_min_class_ordinal: parsed.data.minClassOrdinal,
    p_max_class_ordinal: parsed.data.maxClassOrdinal,
  });
  if (error) {
    if (error.message.includes('INVALID_ORDINAL_RANGE')) return { error: 'The starting class must be at or before the ending class.' };
    if (error.message.includes('STAFF_NOT_FOUND')) return { error: 'This teacher could not be found.' };
    if (error.message.includes('SUBJECT_NOT_FOUND')) return { error: 'This subject could not be found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to manage teacher competencies.' };
    return { error: 'Could not save the competency.' };
  }

  revalidatePath('/academic-setup/competency');
  return { error: null };
}

// FR-E07: HR marks a declared/inferred competency Verified against a
// document. Requires an existing row — verify_competency() is a
// confirmation step, not a way to create a fresh one.
export async function verifyCompetency(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = verifyCompetencySchema.safeParse({
    staffId: formData.get('staffId'),
    subjectId: formData.get('subjectId'),
    documentPath: formData.get('documentPath') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('verify_competency', {
    p_staff_id: parsed.data.staffId,
    p_subject_id: parsed.data.subjectId,
    p_document_path: parsed.data.documentPath,
  });
  if (error) {
    if (error.message.includes('COMPETENCY_NOT_FOUND')) return { error: 'Declare a competency for this teacher and subject first.' };
    if (error.message.includes('STAFF_NOT_FOUND')) return { error: 'This teacher could not be found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to verify teacher competencies.' };
    return { error: 'Could not verify the competency.' };
  }

  revalidatePath('/academic-setup/competency');
  return { error: null };
}

export type SubstituteCandidate = {
  staff_id: string;
  full_name: string;
  source: 'DECLARED' | 'INFERRED' | 'VERIFIED';
  min_class_ordinal: number;
  max_class_ordinal: number;
  out_of_range: boolean;
};
export type SuggestSubstitutesState = { error: string | null; candidates: SubstituteCandidate[] | null };

// FR-E07 AC1: ranked substitute candidates for a subject+class — exact
// matches first, out-of-range candidates still returned (never hidden),
// flagged instead.
export async function suggestSubstitutes(_prev: SuggestSubstitutesState, formData: FormData): Promise<SuggestSubstitutesState> {
  const parsed = suggestSubstitutesSchema.safeParse({
    subjectId: formData.get('subjectId'),
    classLevelId: formData.get('classLevelId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', candidates: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('suggest_substitute_teachers', {
    p_subject_id: parsed.data.subjectId,
    p_class_level_id: parsed.data.classLevelId,
  });
  if (error) {
    if (error.message.includes('SUBJECT_NOT_FOUND')) return { error: 'This subject could not be found.', candidates: null };
    if (error.message.includes('CLASS_LEVEL_NOT_FOUND')) return { error: 'This class could not be found.', candidates: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to view substitute suggestions.', candidates: null };
    return { error: 'Could not find substitutes.', candidates: null };
  }

  return { error: null, candidates: (data as SubstituteCandidate[]) ?? [] };
}
