'use server';

import { revalidatePath } from 'next/cache';
import { createFeeHeadSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-K01: seed the 8 default fee heads for a tenant with none yet.
export async function seedFeeHeads(tenantId: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('seed_default_fee_heads', { p_tenant_id: tenantId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to seed fee heads.' };
    return { error: 'Could not seed fee heads.' };
  }

  revalidatePath('/fees/heads');
  return { error: null };
}

// FR-K01: create a fee head. Case-insensitive code uniqueness is enforced
// by fee_head_tenant_code_uq — this action only shapes the client-facing
// error for that raw constraint violation.
export async function createFeeHead(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createFeeHeadSchema.safeParse({
    code: formData.get('code'),
    nameEn: formData.get('nameEn'),
    nameUr: formData.get('nameUr'),
    isRefundable: formData.get('isRefundable') === 'on',
    defaultFrequency: formData.get('defaultFrequency'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_fee_head', {
    p_code: parsed.data.code,
    p_name_en: parsed.data.nameEn,
    p_name_ur: parsed.data.nameUr,
    p_is_refundable: parsed.data.isRefundable,
    p_default_frequency: parsed.data.defaultFrequency,
  });
  if (error) {
    if (error.message.includes('duplicate key')) return { error: `A fee head with code "${parsed.data.code}" already exists.` };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create fee heads.' };
    return { error: 'Could not create the fee head.' };
  }

  revalidatePath('/fees/heads');
  return { error: null };
}

// FR-K01: activate/deactivate a fee head — never deletes, never touches
// any ledger row that already references it.
export async function setFeeHeadActive(id: string, isActive: boolean, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_fee_head_active', { p_id: id, p_is_active: isActive });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to change fee heads.' };
    if (error.message.includes('FEE_HEAD_NOT_FOUND')) return { error: 'Fee head not found.' };
    return { error: 'Could not update the fee head.' };
  }

  revalidatePath('/fees/heads');
  return { error: null };
}
