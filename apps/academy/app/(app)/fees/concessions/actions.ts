'use server';

import { revalidatePath } from 'next/cache';
import { createConcessionSchemeSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-K05: create a concession scheme. Value-range and non-empty-heads
// checks are DB constraints (ck_concession_value_range,
// ck_concession_applicable_heads_not_empty) — this action only shapes the
// client-facing error for those and for the case-insensitive code clash.
export async function createConcessionScheme(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createConcessionSchemeSchema.safeParse({
    code: formData.get('code'),
    nameEn: formData.get('nameEn'),
    nameUr: formData.get('nameUr'),
    calcType: formData.get('calcType'),
    value: formData.get('value'),
    applicableHeadIds: formData.getAll('applicableHeadIds'),
    requiresDocument: formData.get('requiresDocument') === 'on',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_concession_scheme', {
    p_code: parsed.data.code,
    p_name_en: parsed.data.nameEn,
    p_name_ur: parsed.data.nameUr,
    p_calc_type: parsed.data.calcType,
    p_value: parsed.data.value,
    p_applicable_head_ids: parsed.data.applicableHeadIds,
    p_requires_document: parsed.data.requiresDocument,
  });
  if (error) {
    if (error.message.includes('duplicate key')) return { error: `A scheme with code "${parsed.data.code}" already exists.` };
    if (error.message.includes('ck_concession_value_range')) return { error: 'A percentage value cannot exceed 100.' };
    if (error.message.includes('FEE_HEAD_NOT_FOUND')) return { error: 'One of the selected fee heads was not found.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create concession schemes.' };
    return { error: 'Could not create the scheme.' };
  }

  revalidatePath('/fees/concessions');
  return { error: null };
}

export async function setConcessionSchemeActive(id: string, isActive: boolean, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_concession_scheme_active', { p_id: id, p_is_active: isActive });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to change concession schemes.' };
    return { error: 'Could not update the scheme.' };
  }

  revalidatePath('/fees/concessions');
  return { error: null };
}
