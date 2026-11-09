'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { payScaleSchema } from './schema';

export async function savePayScale(input: unknown): Promise<{ error: string | null }> {
  const p = payScaleSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the pay scale.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_pay_scale', {
    p_id: v.id || null,
    p_code: v.code,
    p_name: v.name,
    p_min_basic_paisa: Number(v.minPkr) * 100,
    p_max_basic_paisa: Number(v.maxPkr) * 100,
    p_annual_increment_paisa: Number(v.incrementPkr) * 100,
  });
  if (error) {
    if (error.code === '23505') return { error: 'A pay scale with that code already exists.' };
    if (error.message.includes('BAND_INVALID')) return { error: 'The maximum must be at least the minimum.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR or the owner can change pay scales.' };
    return { error: 'Something went wrong. Try again.' };
  }
  revalidatePath('/payroll/pay-scales');
  return { error: null };
}
