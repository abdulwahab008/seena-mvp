'use server';

import { revalidatePath } from 'next/cache';
import { setDocumentRequirementSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-B09: configure which documents are mandatory for a class band.
// Effective-dating (the previous rule for the same campus+doc_type
// closes out, never rewritten) is enforced inside set_document_requirement()
// itself.
export async function setDocumentRequirement(campusId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = setDocumentRequirementSchema.safeParse({
    campusId,
    minClassOrdinal: formData.get('minClassOrdinal'),
    maxClassOrdinal: formData.get('maxClassOrdinal'),
    docType: formData.get('docType'),
    isMandatory: formData.get('isMandatory') === 'on',
    minCount: formData.get('minCount'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_document_requirement', {
    p_campus_id: parsed.data.campusId,
    p_min_class_ordinal: parsed.data.minClassOrdinal,
    p_max_class_ordinal: parsed.data.maxClassOrdinal,
    p_doc_type: parsed.data.docType,
    p_is_mandatory: parsed.data.isMandatory,
    p_min_count: parsed.data.minCount,
  });
  if (error) {
    if (error.message.includes('INVALID_ORDINAL_RANGE')) return { error: 'The starting class must be at or before the ending class.' };
    if (error.message.includes('MIN_COUNT_MUST_BE_POSITIVE')) return { error: 'Count must be at least 1.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure the document checklist.' };
    return { error: 'Could not save the requirement.' };
  }

  revalidatePath('/admissions/checklist');
  return { error: null };
}
