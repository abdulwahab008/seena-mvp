'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { installmentFormSchema, splitPlan } from './plan';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the accountant, Principal or owner can set installments.';
  if (m.includes('CHALLAN_CLOSED')) return 'Only an unpaid or part-paid challan can be split.';
  if (m.includes('PLAN_TOTAL_MISMATCH')) return 'The installments must add up to the challan amount.';
  if (m.includes('PLAN_DATES_ORDER')) return 'Each installment must fall due after the one before it.';
  return 'Something went wrong. Try again.';
}

export async function setInstallments(input: unknown): Promise<{ error: string | null; parts?: number }> {
  const p = installmentFormSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: challan } = await supabase.from('fee_challan').select('id, net_paisa, status').eq('challan_no', p.data.challanNo).is('deleted_at', null).maybeSingle();
  if (!challan) return { error: 'No challan has that number.' };
  const plan = splitPlan(challan.net_paisa, Number(p.data.parts), p.data.firstDue);
  const { error } = await supabase.rpc('set_challan_installments', { p_challan_id: challan.id, p_plan: plan });
  if (error) return { error: message(error.message) };
  revalidatePath('/fees/installments');
  return { error: null, parts: plan.length };
}
