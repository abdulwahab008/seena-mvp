'use server';

import { revalidatePath } from 'next/cache';
import { createLateFeeRuleSchema, previewLateFeeSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

export async function createLateFeeRule(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createLateFeeRuleSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    basis: formData.get('basis'),
    graceDays: formData.get('graceDays'),
    amountRupees: formData.get('amountRupees') || undefined,
    percentage: formData.get('percentage') || undefined,
    capRupees: formData.get('capRupees') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_late_fee_rule', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_basis: parsed.data.basis,
    p_grace_days: parsed.data.graceDays,
    p_amount_paisa: parsed.data.amountRupees !== undefined ? Math.round(parsed.data.amountRupees * 100) : undefined,
    p_percentage: parsed.data.percentage,
    p_cap_paisa: parsed.data.capRupees !== undefined ? Math.round(parsed.data.capRupees * 100) : undefined,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure late fee rules.' };
    if (error.message.includes('PERCENTAGE_REQUIRED')) return { error: 'Enter a percentage.' };
    if (error.message.includes('AMOUNT_REQUIRED')) return { error: 'Enter an amount.' };
    return { error: 'Could not create the rule.' };
  }

  revalidatePath('/fees/late-fee-rules');
  return { error: null };
}

export type PreviewState = { error: string | null; amountPaisa?: number };

export async function previewLateFee(_prev: PreviewState, formData: FormData): Promise<PreviewState> {
  const parsed = previewLateFeeSchema.safeParse({
    challanId: formData.get('challanId'),
    asOf: formData.get('asOf'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('compute_late_fee', {
    p_challan_id: parsed.data.challanId,
    p_as_of: parsed.data.asOf,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to preview late fees.' };
    if (error.message.includes('CHALLAN_NOT_FOUND')) return { error: 'Challan not found.' };
    return { error: 'Could not compute the late fee.' };
  }

  return { error: null, amountPaisa: data as number };
}
